#!/usr/bin/env Rscript
# "Script to pretty-display cost of runnning a cromwell job retrieved from Big Query"

library("optparse", warn.conflicts = F, quietly = T)

parser <- OptionParser()
parser <- add_option(parser, c("-j", "--json"), type='character',
                     help="JSON file downloaded from BigQuery on costs of a particular job run")

parser <- add_option(parser, c("-p", "--plot"), type='character',
                     help="File name to store the cost plot")

parser <- add_option(parser, c("-w", "--width"), type='double',
                     default = 10,
                     help="Width of the plot")

parser <- add_option(parser, c("--height"), type='double',
                     default = 10,
                     help="Height of the plot")

parser <- add_option(parser, c("-m", "--md"), type='character',
                     default = NA,
                     help="File name to store the detailed cost, formated in markdown (optional)")
################################################################################
summarize_cost <- function(big.query.json.file,
                           plot.pdf,
                           width, height,
                           markdown.table.md = NA) {
    library("jsonlite", warn.conflicts = F, quietly = T)
    library("knitr", warn.conflicts = F, quietly = T)
    library("dplyr", warn.conflicts = F, quietly = T)
    library("ggplot2", warn.conflicts = F, quietly = T)
    library("gridExtra", warn.conflicts = F, quietly = T)

    json = fromJSON(big.query.json.file)

    json$"sku_description" = gsub(" running in Americas", "", json$"sku_description")

    json$"cost" = as.numeric(json$"cost")
    json = json[order(json$"cost", decreasing = T), ]

    total.cost = sum(json$"cost")

    # cut down, but other info maybe useful later
    presentation = json[,c('cost', 'sku_description')]
    names.arr = apply(json, 1,
                      function(e) {
                          if (is.na(e[['task_alias']])) e[['task_name']] else e[['task_alias']]
                      })
    presentation["task"] = names.arr
    names(presentation)= c("unitcost", "sku", "task")
    presentation$"sku" = as.factor(presentation$"sku")
    presentation$"task" = as.factor(presentation$"task")

    ##########
    # save markdown table, if requested
    if (!is.na(markdown.table.md) & !is.null(markdown.table.md)) {
        sink(markdown.table.md)
        md.table = kable(presentation, caption = sprintf("Total cost: %.2f", total.cost),
                         format = "markdown", row.names = F)
        print( md.table )
        sink()
    }

    ##########
    # save figures
    per.task <- presentation %>%
        group_by(task) %>%
        summarise(cost = sum(unitcost)) %>%
        mutate(share=cost/sum(cost)*100.0) %>%
        arrange(desc(cost))
    # # bar chart giving quick glance into which task costs how much percentage
    # # https://tinyurl.com/ya58xjtp
    # p = ggplot(per.task, aes("", share, fill = task)) +
    #     geom_bar(width = 1, size = 1, color = "white", stat = "identity") +
    #     coord_polar("y") +
    #     geom_text(aes(label = paste0(round(share), "%")),
    #               position = position_stack(vjust = 0.5)) +
    #     labs(x = NULL, y = NULL, fill = NULL,
    #          title = sprintf("Cost share per task class out of total cost: %.2f", total.cost)) +
    #     guides(fill = guide_legend(reverse = TRUE)) +
    #     theme_classic() +
    #     theme(axis.line = element_blank(),
    #           axis.text = element_blank(),
    #           axis.ticks = element_blank(),
    #           plot.title = element_text(hjust = 0.5))

    # real output, break down per task, then within each task, break down per SKU
    per.sku.per.task = NULL
    for (t in levels(presentation$"task")) {
        tmp <- presentation %>%
            filter(task == t) %>%
            group_by(sku) %>%
            summarise(cost = sum(unitcost)) %>%
            mutate(share=cost/sum(cost)*100.0) %>%
            arrange(desc(share))
        df = as.data.frame(tmp)
        df = subset(df, select=-c(cost))
        df$"sku" = as.factor(df$"sku")
        df$"task" = t
        if (is.null(per.sku.per.task)) {
            per.sku.per.task = df
        } else {
            per.sku.per.task = rbind.data.frame(per.sku.per.task, df)
        }
    }
    per.sku.per.task$"sku" = as.factor(per.sku.per.task$"sku")
    per.sku.per.task$"task" = factor(per.sku.per.task$"task",
                                     levels = as.character(per.task$task))

    cost.labeller = vector()
    for(t in per.task$"task") {
        s = sprintf("%s: $%.2f", t, per.task$"cost"[ per.task$"task" == t ])
        cost.labeller <- c(cost.labeller, s)
    }
    names(cost.labeller) = per.task$"task"
    n.row = floor( sqrt(length(levels(per.sku.per.task$"task"))) )
    q = ggplot(per.sku.per.task, aes("", share, fill = sku)) +
        geom_bar(color = "white", stat = "identity") +
        coord_polar("y") +
        geom_text(aes(label = paste0(round(share), "%")),
                  position = position_stack(vjust = 0.5)) +
        labs(x = NULL, y = NULL, fill = NULL,
             title = sprintf("Cost per task per SKU (tot. $%.2f)", total.cost)) +
        guides(fill = guide_legend(reverse = TRUE, ncol = 2)) +
        facet_wrap(facets=. ~ task, nrow = n.row,
                   labeller = as_labeller(cost.labeller))  +
        # theme_classic() +
        theme(axis.line = element_blank(),
              axis.text = element_blank(),
              axis.ticks = element_blank(),
              plot.title = element_text(hjust = 0.5),
              legend.position="bottom")
    # if the PDF looks cramed, strange, change the following parameters
    ggsave(plot.pdf, plot = q, width = width, height = height)
}
################################################################################
parsed.args = parse_args(parser)
# print(parsed.args)
summarize_cost(parsed.args$"json",
               parsed.args$"plot", parsed.args$"width", parsed.args$"height",
               parsed.args$"md")