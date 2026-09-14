# syntax=docker/dockerfile:1
#
# Container image for the wxpipe ingestion job (a Cloud Run Job: it runs to
# completion and exits; there is no HTTP listener).
#
# Two stages:
#   builder  restores the R packages wxpipe needs at runtime from renv.lock as
#            Posit Package Manager binaries and installs wxpipe itself;
#   final    the same R base image with the compilers removed, the restored
#            library copied in, and a non-root user.
#
# Build locally (from the repository root):
#   docker build --build-arg WXPIPE_GIT_SHA="$(git rev-parse HEAD)" -t wxpipe .

# Pin the R minor *and* patch version; it must match renv.lock and CI.
ARG R_VERSION=4.5.3

# -----------------------------------------------------------------------------
FROM rocker/r-ver:${R_VERSION} AS builder

# RENV_CONFIG_PPM_ENABLED turns the Posit Package Manager URL recorded in
#   renv.lock into Linux binary URLs, so nothing is compiled from source.
# RENV_CONFIG_CACHE_SYMLINKS=FALSE copies packages out of the build cache
#   instead of symlinking to it; the cache mount is not part of the image.
ENV RENV_CONFIG_PPM_ENABLED=TRUE \
    RENV_CONFIG_CACHE_SYMLINKS=FALSE \
    RENV_PATHS_CACHE=/opt/renv-cache \
    WXPIPE_LIBRARY=/opt/wxpipe/library

# Restore packages first, in their own layer, so code changes do not trigger
# a re-install. The renv bootstrap files install the exact renv version
# recorded in the lockfile (pattern from renv's Docker vignette).
WORKDIR /build/renv-project
COPY renv.lock .Rprofile DESCRIPTION ./
COPY renv/activate.R renv/settings.json renv/

# Restore only wxpipe's runtime dependencies (its DESCRIPTION Imports and their
# recursive dependencies) -- not testthat, webfakes and other test tooling.
RUN --mount=type=cache,target=/opt/renv-cache \
    mkdir -p "${WXPIPE_LIBRARY}" \
    && Rscript -e ' \
      imports <- strsplit(read.dcf("DESCRIPTION", fields = "Imports")[1, 1], ",")[[1]]; \
      imports <- trimws(gsub("[(].*", "", imports)); \
      locked <- names(renv::lockfile_read("renv.lock")$Packages); \
      renv::restore( \
        library = Sys.getenv("WXPIPE_LIBRARY"), \
        packages = intersect(imports, locked), \
        prompt = FALSE \
      ) \
    '

# Install wxpipe itself into the same library. This runs outside the renv
# project directory so that renv is not activated for the install.
WORKDIR /build/wxpipe
COPY DESCRIPTION NAMESPACE LICENSE ./
COPY R/ R/
COPY inst/ inst/
COPY man/ man/
COPY exec/ exec/
RUN R_LIBS="${WXPIPE_LIBRARY}" R CMD INSTALL --no-docs --library="${WXPIPE_LIBRARY}" .

# -----------------------------------------------------------------------------
FROM rocker/r-ver:${R_VERSION}

# rocker/r-ver keeps g++, gfortran and make installed so that users can build
# packages from source. This image never builds anything, so they are removed.
# The runtime libraries that R and LAPACK link against are marked as manually
# installed first, so that --auto-remove cannot take them along. libuv is the
# runtime counterpart of the libuv1-dev system requirement of the fs package.
RUN apt-mark manual libgfortran5 libgomp1 libquadmath0 \
    && apt-get purge -y --auto-remove g++ gcc gfortran make cpp \
    && apt-get update \
    && apt-get install -y --no-install-recommends libuv1t64 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/wxpipe/library /opt/wxpipe/library
COPY exec/ingest.R /app/ingest.R

# R_LIBS puts the restored library first on the library path.
# WXPIPE_GIT_SHA is stamped onto every loaded row as part of _pipeline_version.
ARG WXPIPE_GIT_SHA=""
ENV R_LIBS=/opt/wxpipe/library \
    WXPIPE_GIT_SHA=${WXPIPE_GIT_SHA}

# Run as an unprivileged system user. rocker/r-ver ships no default user.
RUN useradd --system --uid 10001 --user-group --create-home \
      --home-dir /home/wxpipe --shell /usr/sbin/nologin wxpipe
USER wxpipe
WORKDIR /app

# Fail the build, rather than the first scheduled run, if a compiler survived
# or the pipeline cannot be loaded by the runtime user.
RUN if command -v gcc || command -v g++ || command -v gfortran || command -v make; then \
      echo "A build toolchain is still present in the final image." >&2; \
      exit 1; \
    fi \
    && Rscript -e 'library(wxpipe); invisible(read_sources_config()); cat("wxpipe", pipeline_version(), "\n")'

# Cloud Run Jobs can override the arguments per execution, e.g.
#   gcloud run jobs execute wxpipe-ingest --args="--mode=backfill,..."
ENTRYPOINT ["Rscript", "/app/ingest.R"]
CMD ["--source=all", "--mode=daily"]
