# Copyright © 2016 RTE Réseau de transport d’électricité

#' Compute the modulation of cluster units
#'
#' This function computes the modulation of cluster units or of sectors.
#'
#' @param x
#'   An \code{antaresData} object created with \code{readAntares}. It must
#'   contain the hourly detailed results for clusters if \code{by = "cluster"}
#'   or for areas and/or districts if \code{by = "sector"}
#' @param by
#'   Should modulations computed by cluster or by sector? Possible values are
#'   "sector" and "cluster".
#' @param opts opts where clusterDesc will be read if null based on data
#' @inheritParams surplus
#' @inheritParams surplusClusters
#'
#' @return
#' A data.table of class \code{antaresDataTable} or a list of such tables with
#' the following columns:
#' \item{area}{
#'   Area name. If \code{byDistrict=TRUE}, this column is replaced by column
#'   \code{district}.
#' }
#' \item{cluster}{
#'   Cluster name. If \code{by="sector"}, this column is replaced by column
#'   \code{sector}.
#' }
#' \item{timeId}{
#'   Time id and other time columns.
#' }
#' \item{upwardModulation}{
#'   Maximal absolute modulation of a cluster unit or of the sector, if \code{timeStep} is hourly.
#' }
#' \item{downwardModulation}{
#'   Maximal absolute modulation of a cluster unit or of the sector, if \code{timeStep} is hourly.
#' }
#' \item{absoluteModulation}{
#'   Maximal absolute modulation of a cluster unit or of the sector, if \code{timeStep} is hourly.
#' }
#' \item{avg_upwardModulation}{
#'   Average upward modulation of a cluster unit or of the sector, if \code{timeStep} is not hourly.
#' }
#' \item{avg_downwardModulation}{
#'   Average downward modulation of a cluster unit or of the sector, if \code{timeStep} is not hourly.
#' }
#' \item{avg_absoluteModulation}{
#'   Average absolute modulation of a cluster unit or of the sector, if \code{timeStep} is not hourly.
#' }
#' \item{max_upwardModulation}{
#'   Maximal upward modulation of a cluster unit or of the sector, if \code{timeStep} is not hourly.
#' }
#' \item{max_downwardModulation}{
#'   Maximal downward modulation of a cluster unit or of the sector, if \code{timeStep} is not hourly.
#' }
#' \item{max_absoluteModulation}{
#'   Maximal absolute modulation of a cluster unit or of the sector, if \code{timeStep} is not hourly.
#' }
#'
#' Notice that if \code{by="cluster"}, the function computes the modulation per
#' unit, i.e. the modulation of a cluster divided by the number of units of the
#' cluster. On the opposite, if \code{by="sector"}, the function returns the
#' modulation of the global production of the sector. Moreover, if parameter
#' \code{x} contains area and district data, the function returns a list with
#' components \code{areas} and  \code{districts}.
#'
#' @examples
#' \dontrun{
#' # data required by the function
#' showAliases("modulation")
#'
#' mydata <- readAntares(select="modulation")
#'
#' # Modulation of cluster units
#' modulation(mydata)
#'
#' # Aggregate Monte-Carlo scenarios
#' modulation(mydata, synthesis = TRUE)
#'
#' # Modulation of sectors
#' modulation(mydata, by = "sector")
#'
#' # Modulation of sectors per district
#' modulation(mydata, by = "sector")
#' }
#'
#' @export
#'
modulation <- function(x, timeStep = "annual", synthesis = FALSE,
                       by = c("cluster", "sector"), clusterDesc = NULL, opts = NULL) {
  by <- match.arg(by)

  x <- .checkAttrs(x, timeStep = "hourly", synthesis = FALSE)
  if(is.null(opts))
  {
    opts <- simOptions(x)
  }

  # The code below does the following:
  #
  # - If by = cluster, use cluster data to compute modulations
  # - If by = sector:
  #   - If x is an antaresDataTable return a data.table with sector modulations
  #   - Else if x is an antaresDataList:
  #     - error if x has no component areas or districts
  #     - return a data.table if only one component areas or districts
  #     - return a list if it has the two components areas and districts

  if (by == "cluster") {

    x <- .checkColumns(x, list(clusters = "production"))

    # Add variable unitcount to the table containing the production of clusters
    if (is.null(clusterDesc)) clusterDesc <- readClusterDesc(opts)
    tmp <- merge(x$clusters,
                 clusterDesc[, .(area, cluster, unitcount)],
                 by = c("area", "cluster"))

    return(.computeModulation(tmp, timeStep, synthesis, opts))

  } else { # by = "sector"

    if (is(x, "antaresDataTable")) {

      if (! attr(x, "type") %in% c("areas", "districts"))
        stop("x needs to contain area or district data.")

      tmp <- .prodPerSector(x)
      return(.computeModulation(tmp, timeStep, synthesis, opts))

    } else { # 'x' is an antaresDataList

      res <- list()
      if (!is.null(x$areas)) {
        tmp <- .prodPerSector(x$areas)
        res$areas <- .computeModulation(tmp, timeStep, synthesis, opts)
      }
      if (!is.null(x$districts)) {
        tmp <- .prodPerSector(x$districts)
        res$districts <- .computeModulation(tmp, timeStep, synthesis, opts)
      }

      if (length(res) == 0) stop("x needs to contain area and/or district data and at least one sector production (NUCLEAR, LIGNITE, ...).")

      .addClassAndAttributes(res, synthesis, timeStep, opts, simplify = TRUE)
    }
  }
}

.computeModulation <- function(x, timeStep, synthesis, opts) {
  # Compute production at t-1. A bit hacky but saves a lot of time !
  setorderv(x, .idCols(x))
  x[, shiftProd := ifelse(timeId == min(timeId), 0, shift(production))]

  # Modulations
  res <- x[, append(mget(.idCols(x)),
                    .(upwardModulation = pmax(0, production - shiftProd) / unitcount,
                      downwardModulation = pmax(0, shiftProd - production) / unitcount,
                      absoluteModulation = abs(production - shiftProd) / unitcount))]

  res <- .addClassAndAttributes(res, FALSE, "hourly", opts, type = "modulations")

  # Aggregation

  if (synthesis) {

    res <- synthesize(res, "max", prefixForMeans = "avg")
    res <- changeTimeStep(res, timeStep,
                          fun = c("mean", "max", "mean", "max", "mean", "max"))

  } else if (timeStep != "hourly") {

    res[, max_upwardModulation := upwardModulation]
    res[, max_downwardModulation := downwardModulation]
    res[, max_absoluteModulation := absoluteModulation]

    res <- changeTimeStep(res, timeStep,
                          fun = c("mean", "mean", "mean", "max", "max", "max"))

    setcolorder(res, c(.idCols(res),
                       "upwardModulation", "max_upwardModulation",
                       "downwardModulation", "max_downwardModulation",
                       "absoluteModulation", "max_absoluteModulation"))

    setnames(res,
             c("upwardModulation", "downwardModulation", "absoluteModulation"),
             c("avg_upwardModulation", "avg_downwardModulation", "avg_absoluteModulation"))

  }

  res
}


#' Private function that creates a table with columns area, sector, timeId,
#' mcYear and production. The later column contains the production of the sector
#'
#' @param x
#'   data.table of class antaresDataTable with type "areas" or "districts".
#' @noRd
.prodPerSector <- function(x) {
  sectors <- pkgEnv$production

  sectors <- intersect(sectors, names(x))
  if (length(sectors) == 0) return(NULL)

  idVars <- .idCols(x)

  res <- melt(x[, c(idVars, sectors), with = FALSE], id.vars = idVars,
              variable.name = "sector", value.name = "production")

  res$unitcount <- 1L

  res
}
