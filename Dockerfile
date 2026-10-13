# Public demo of Pingvin Share X on Fly.io. The base image is the app itself,
# built from the demo branch of dzaczek/pingvin-share-x.
ARG BASE_IMAGE=ghcr.io/dzaczek/pingvin-share-x-demo-base:latest
FROM ${BASE_IMAGE}

COPY demo /opt/demo

# the demo data is built here, once, so an idle machine that was stopped is
# back in a few seconds instead of a minute or two
RUN sh /opt/demo/run.sh template \
    && mkdir -p /opt/demo/state \
    && chown -R 1000:1000 /opt/demo

# the base entrypoint drops to uid 1000 before this runs
CMD ["sh", "/opt/demo/run.sh"]
