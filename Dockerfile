FROM rocker/shiny:4.5.0

# System dependencies for R packages (httr, xml2, openssl, glpk, CVXR)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    libglpk-dev \
    libuv1-dev \
    && rm -rf /var/lib/apt/lists/*

# Install renv for reproducible dependency restore
RUN R -e "install.packages('renv', repos='https://cloud.r-project.org')"

WORKDIR /app

# Copy renv lockfile first (layer caching — deps rebuild only when lock changes)
COPY renv.lock renv.lock

# Restore all packages from lockfile
RUN R -e "renv::restore(lockfile = 'renv.lock', library = .libPaths()[1], prompt = FALSE)"

# Copy the rest of the project
COPY . .

EXPOSE 3838

CMD ["R", "-e", "source('app.R')"]
