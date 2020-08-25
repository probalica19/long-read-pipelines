version 1.0

##########################################################################################
## A workflow that performs CCS correction on PacBio HiFi reads from a single flow cell.
## The workflow shards the subreads into clusters and performs CCS in parallel on each cluster.
## Ultimately, all the corrected reads (and uncorrected) are gathered into a single BAM.
## Various metrics are produced along the way.
##########################################################################################

import "tasks/PBUtils.wdl" as PB
import "tasks/ShardUtils.wdl" as SU
import "tasks/Utils.wdl" as Utils
import "tasks/Finalize.wdl" as FF

import "tasks/ShardPacBioSubReadsUBamByZMWClusterSpark.wdl" as SparkShard

workflow PBCCSOnlySingleFlowcell {
    input {
        String raw_reads_gcs_bucket

        String? sample_name

        Int? shard_size

        String gcs_out_root_dir
    }

    parameter_meta {
        raw_reads_gcs_bucket: "GCS bucket holding subreads BAMs (and other related files) holding the sequences to be CCS-ed"
        sample_name:          "[optional] name of sample this FC is sequencing"
        num_reads_per_split:  "[default-valued] number of subreads each sharded BAM contains (tune for performance)"
        gcs_out_root_dir :    "GCS bucket to store the corrected/uncorrected reads and metrics files"
    }

    String outdir = sub(gcs_out_root_dir, "/$", "")

    call PB.FindBams { input: gcs_input_dir = raw_reads_gcs_bucket }

    # double scatter: one FC may generate multiple raw BAMs, we perform another layer scatter on each of these BAMs
    scatter (subread_bam in FindBams.subread_bams) {
        call PB.GetRunInfo { input: subread_bam = subread_bam }

        String SM  = select_first([sample_name, GetRunInfo.run_info["SM"]])
        String PU  = GetRunInfo.run_info["PU"]
        String ID  = PU
        String DIR = SM + "." + ID

        call SparkShard.ShardPacBioSubReadsUBamByZMWClusterSpark as ShardUBAM {
            input:
                input_ubam = subread_bam,
                shard_size = shard_size,
                output_prefix = SM + ".SparkShard"
        }

        scatter (subreads in ShardUBAM.split_bam) {
            call PB.CCSWithReHeader as CCS {
            	input:
            		subreads = subreads,
            		original_header_hd_line = ShardUBAM.original_header_hd_line
            	}
        }

        # merge the corrected per-shard BAM/report into one, corresponding to one raw input BAM
        call Utils.MergeBams as MergeChunks { input: bams = CCS.consensus, prefix = "~{SM}.~{ID}", disk_size_estimate = 3*ceil(size(subread_bam, "GB"))}
        call PB.MergeCCSReports as MergeCCSReports { input: reports = CCS.report }
    }

    # gather across (potential multiple) input raw BAMs
    if (length(FindBams.subread_bams) > 1) {
        call Utils.MergeBams as MergeRuns { input: bams = MergeChunks.merged_bam, prefix = "~{SM[0]}.~{ID[0]}" }
        call PB.MergeCCSReports as MergeAllCCSReports { input: reports = MergeCCSReports.report }
    }

    File ccs_bam = select_first([ MergeRuns.merged_bam, MergeChunks.merged_bam[0] ])
    File ccs_report = select_first([ MergeAllCCSReports.report, MergeCCSReports.report[0] ])

    ##########
    # store the results into designated bucket
    ##########

    call FF.FinalizeToDir as FinalizeMergedRuns {
        input:
            files = [ ccs_bam ],
            outdir = outdir + "/" + DIR[0] + "/alignments"
    }

    call FF.FinalizeToDir as FinalizeCCSMetrics {
        input:
            files = [ ccs_report ],
            outdir = outdir + "/" + DIR[0] + "/metrics/ccs_metrics"
    }
}
