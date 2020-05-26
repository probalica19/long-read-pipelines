version 1.0

import "https://raw.githubusercontent.com/broadinstitute/long-read-pipelines/lrp_2.1.10/wdl/tasks/Canu.wdl" as Canu
import "https://raw.githubusercontent.com/broadinstitute/long-read-pipelines/lrp_2.1.10/wdl/tasks/Quast.wdl" as Quast
import "https://raw.githubusercontent.com/broadinstitute/long-read-pipelines/lrp_2.1.10/wdl/tasks/Finalize.wdl" as FF

workflow CanuRunner {
    input {
        String reads_fastq_dir
        String output_file_prefix
        String genome_size
        Float correct_correctedErrorRate
        Float trim_correctedErrorRate
        Float assemble_correctedErrorRate

        String out_dir
    }

    call ListFastqFiles {
        input:
            dir = reads_fastq_dir
    }

    call Canu.CorrectTrimAssemble {
        input:
            output_file_prefix = output_file_prefix,
            genome_size = genome_size,
            reads_fastq = read_lines(ListFastqFiles.fastq_list),
            correct_corrected_error_rate = correct_correctedErrorRate,
            trim_corrected_error_rate = trim_correctedErrorRate,
            assemble_corrected_error_rate = assemble_correctedErrorRate
    }

    call FF.FinalizeToDir as FinalizeAssembly {
        input:
            files = [CorrectTrimAssemble.canu_contigs_fasta],
            outdir = out_dir + "/assembly"
    }
}

task ListFastqFiles {
    input {
        String dir
    }

    String input_dir = sub(dir, "/$", "")

    command <<<
        set -euxo pipefail

        gsutil ls ~{input_dir}/*.fastq > fastq_list.txt
    >>>

    output {
        File fastq_list = "fastq_list.txt"
    }

    runtime {
        cpu:                    1
        memory:                 "1 GiB"
        disks:                  "local-disk 1 HDD"
        bootDiskSizeGb:         10
        preemptible:            0
        maxRetries:             0
        docker:                 "us.gcr.io/broad-dsp-lrma/lr-utils:0.1.6"
    }
}