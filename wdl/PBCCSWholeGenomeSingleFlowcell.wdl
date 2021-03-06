version 1.0

##########################################################################################
## A workflow that performs CCS correction and variant calling on PacBio HiFi reads from a
## single flow cell. The workflow shards the subreads into clusters and performs CCS in
## parallel on each cluster.  Error-corrected reads are then variant-called.  A number of
## metrics and figures are produced along the way.
##########################################################################################

import "tasks/PBUtils.wdl" as PB
import "tasks/Utils.wdl" as Utils
import "tasks/AlignReads.wdl" as AR
import "tasks/AlignedMetrics.wdl" as AM
import "tasks/CallSVs.wdl" as SV
import "tasks/Figures.wdl" as FIG
import "tasks/Finalize.wdl" as FF
import "tasks/CallSmallVariants.wdl" as SMV

workflow PBCCSWholeGenomeSingleFlowcell {
    input {
        String raw_reads_gcs_bucket
        String? sample_name

        File ref_fasta
        File ref_fasta_fai
        File ref_dict

        File tandem_repeat_bed
        File ref_flat
        File dbsnp_vcf
        File dbsnp_tbi

        String mt_chr_name
        File metrics_locus

        Int num_shards = 300
        Boolean extract_uncorrected_reads = false

        String gcs_out_root_dir
    }

    parameter_meta {
        raw_reads_gcs_bucket:      "GCS bucket holding subreads BAMs (and other related files) holding the sequences to be CCS-ed"
        sample_name:               "[optional] name of sample this FC is sequencing"

        ref_fasta:                 "Reference fasta file"
        ref_fasta_fai:             "Index (.fai) for the reference fasta file"
        ref_dict:                  "Sequence dictionary (.dict) for the reference fasta file"

        tandem_repeat_bed:         "BED file specifying the location of tandem repeats in the reference"
        ref_flat:                  "Gene predictions in refFlat format (https://genome.ucsc.edu/goldenpath/gbdDescriptions.html)"
        dbsnp_vcf:                 "dbSNP vcf"
        dbsnp_tbi:                 "Index (.tbi) for dbSNP vcf"

        mt_chr_name:               "Contig name for the mitochondrial sequence in the reference"
        metrics_locus:             "Loci over which some summary metrics should be computed"

        num_shards:                "[default-valued] number of sharded BAMs to create (tune for performance)"
        extract_uncorrected_reads: "[default-valued] extract reads that were not CCS-corrected to a separate file"

        gcs_out_root_dir :         "GCS bucket to store the corrected/uncorrected reads and metrics files"
    }

    String outdir = sub(gcs_out_root_dir, "/$", "")

    call PB.FindBams { input: gcs_input_dir = raw_reads_gcs_bucket}

    # double scatter: one FC may generate multiple raw BAMs, we perform another layer scatter on each of these BAMs
    scatter (subread_bam in FindBams.subread_bams) {
        call PB.GetRunInfo { input: subread_bam = subread_bam }

        String SM  = select_first([sample_name, GetRunInfo.run_info["SM"]])
        String PL  = "PACBIO"
        String PU  = GetRunInfo.run_info["PU"]
        String DT  = GetRunInfo.run_info["DT"]
        String ID  = PU
        String DS  = GetRunInfo.run_info["DS"]
        String DIR = SM + "." + ID
        String RG = "@RG\\tID:~{ID}\\tSM:~{SM}\\tPL:~{PL}\\tPU:~{PU}\\tDT:~{DT}"

        # break one raw BAM into fixed number of shards
        File subread_pbi = sub(subread_bam, ".bam$", ".bam.pbi")
        call PB.ShardLongReads { input: unaligned_bam = subread_bam, unaligned_pbi = subread_pbi, num_shards = num_shards }

        # then perform correction and alignment on each of the shard
        scatter (subreads in ShardLongReads.unmapped_shards) {
            call PB.CCS { input: subreads = subreads }

            if (extract_uncorrected_reads) {
                call PB.ExtractUncorrectedReads { input: subreads = subreads, consensus = CCS.consensus }

                call PB.Align as AlignUncorrected {
                    input:
                        bam         = ExtractUncorrectedReads.uncorrected,
                        ref_fasta   = ref_fasta,
                        sample_name = SM,
                        map_preset  = "SUBREAD",
                        runtime_attr_override = { 'mem_gb': 64 }
                }
            }

            call AR.Minimap2 as AlignChunk {
                input:
                    reads      = [ CCS.consensus ],
                    ref_fasta  = ref_fasta,
                    RG         = RG,
                    map_preset = "asm20"
            }
        }

        # merge the corrected per-shard BAM/report into one, corresponding to one raw input BAM
        call Utils.MergeBams as MergeChunks { input: bams = AlignChunk.aligned_bam, prefix = "~{SM}.~{ID}" }
        call PB.MergeCCSReports as MergeCCSReports { input: reports = CCS.report }

        if (length(select_all(AlignUncorrected.aligned_bam)) > 0) {
            call Utils.MergeBams as MergeUncorrectedChunks {
                input:
                    bams = select_all(AlignUncorrected.aligned_bam),
                    prefix = "~{SM}.~{ID}.uncorrected"
            }
        }

        # compute alignment metrics
        call AM.AlignedMetrics as PerFlowcellSubRunMetrics {
            input:
                aligned_bam    = MergeChunks.merged_bam,
                aligned_bai    = MergeChunks.merged_bai,
                ref_fasta      = ref_fasta,
                ref_dict       = ref_dict,
                ref_flat       = ref_flat,
                dbsnp_vcf      = dbsnp_vcf,
                dbsnp_tbi      = dbsnp_tbi,
                metrics_locus  = metrics_locus,
                per            = "flowcell",
                type           = "subrun",
                label          = ID,
                gcs_output_dir = outdir + "/" + DIR
        }

#        call FIG.Figures as PerFlowcellSubRunFigures {
#            input:
#                summary_files  = [ summary_file ],
#
#                per            = "flowcell",
#                type           = "subrun",
#                label          = SID,
#
#                gcs_output_dir = outdir + "/" + DIR
#        }
    }

    # gather across (potential multiple) input raw BAMs
    if (length(FindBams.subread_bams) > 1) {
        call Utils.MergeBams as MergeRuns { input: bams = MergeChunks.merged_bam, prefix = "~{SM[0]}.~{ID[0]}" }
        call PB.MergeCCSReports as MergeAllCCSReports { input: reports = MergeCCSReports.report }

        if (length(select_all(MergeUncorrectedChunks.merged_bam)) > 0) {
            call Utils.MergeBams as MergeAllUncorrectedChunks {
                input:
                    bams = select_all(MergeUncorrectedChunks.merged_bam),
                    prefix = "~{SM[0]}.~{ID[0]}.uncorrected"
            }
        }
    }

    File ccs_bam = select_first([ MergeRuns.merged_bam, MergeChunks.merged_bam[0] ])
    File ccs_bai = select_first([ MergeRuns.merged_bai, MergeChunks.merged_bai[0] ])
    File ccs_report = select_first([ MergeAllCCSReports.report, MergeCCSReports.report[0] ])

    if (extract_uncorrected_reads) {
        File? uncorrected_bam = select_first([ MergeAllUncorrectedChunks.merged_bam, MergeUncorrectedChunks.merged_bam[0] ])
        File? uncorrected_bai = select_first([ MergeAllUncorrectedChunks.merged_bai, MergeUncorrectedChunks.merged_bai[0] ])
    }

    # compute alignment metrics
    call AM.AlignedMetrics as PerFlowcellRunMetrics {
        input:
            aligned_bam    = ccs_bam,
            aligned_bai    = ccs_bai,
            ref_fasta      = ref_fasta,
            ref_dict       = ref_dict,
            ref_flat       = ref_flat,
            dbsnp_vcf      = dbsnp_vcf,
            dbsnp_tbi      = dbsnp_tbi,
            metrics_locus  = metrics_locus,
            per            = "flowcell",
            type           = "run",
            label          = ID[0],
            gcs_output_dir = outdir + "/" + DIR[0]
    }

#    call FIG.Figures as PerFlowcellRunFigures {
#        input:
#            summary_files  = FindSequencingSummaryFiles.summary_files,
#
#            per            = "flowcell",
#            type           = "run",
#            label          = ID[0],
#
#            gcs_output_dir = outdir + "/" + DIR[0]
#    }

    # call SVs
    call SV.CallSVs as CallSVs {
        input:
            bam               = ccs_bam,
            bai               = ccs_bai,

            ref_fasta         = ref_fasta,
            ref_fasta_fai     = ref_fasta_fai,
            tandem_repeat_bed = tandem_repeat_bed,

            preset            = "hifi"
    }

    # call SNVs and small indels
    call SMV.CallSmallVariants as CallSmallVariants {
        input:
            bam               = ccs_bam,
            bai               = ccs_bai,

            ref_fasta         = ref_fasta,
            ref_fasta_fai     = ref_fasta_fai,
            ref_dict          = ref_dict,
    }

    ##########
    # store the results into designated bucket
    ##########

    call FF.FinalizeToDir as FinalizeSVs {
        input:
            files = [ CallSVs.pbsv_vcf, CallSVs.sniffles_vcf, CallSVs.svim_vcf, CallSVs.cutesv_vcf ],
            outdir = outdir + "/" + DIR[0] + "/variants"
    }

    call FF.FinalizeToDir as FinalizeSmallVariants {
        input:
            files = [ CallSmallVariants.longshot_vcf, CallSmallVariants.longshot_tbi ],
            outdir = outdir + "/" + DIR[0] + "/variants"
    }

    call FF.FinalizeToDir as FinalizeCCSMetrics {
        input:
            files = [ ccs_report ],
            outdir = outdir + "/" + DIR[0] + "/metrics/ccs_metrics"
    }


    call FF.FinalizeToDir as FinalizeMergedRuns {
        input:
            files = [ ccs_bam, ccs_bai ],
            outdir = outdir + "/" + DIR[0] + "/alignments"
    }

    if (extract_uncorrected_reads) {
        call FF.FinalizeToDir as FinalizeMergedUncorrectedRuns {
            input:
                files = select_all([ uncorrected_bam, uncorrected_bai ]),
                outdir = outdir + "/" + DIR[0] + "/alignments"
        }
    }
}
