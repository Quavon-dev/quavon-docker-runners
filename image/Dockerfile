# GitHub Actions runner image modeled on GitHub's hosted ubuntu-24.04 image.
#   FLAVOR=standard  git, gh, docker, python, node, build tools, kubectl, helm
#   FLAVOR=full      + Go, Java, .NET, Rust, Ruby, PHP, PowerShell,
#                      Chrome/Firefox, AWS/Azure/GCP CLIs, ansible, kind
#
# The runner binaries themselves are NOT baked in: they live in the per-runner
# directory bind-mounted at the same path on the host, so the runner can
# self-update and so container jobs get correct host paths.
FROM ubuntu:24.04

ARG FLAVOR=standard
ARG NODE_MAJOR=22

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    RUNNER_FLAVOR=${FLAVOR} \
    ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/gha/hooks/job-started.sh \
    ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/opt/gha/hooks/job-completed.sh

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Bootstrap only what the step runner needs; 00-base installs the rest.
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg sudo \
 && rm -rf /var/lib/apt/lists/*

COPY scripts/ /opt/gha/build/

# One layer per step: cached rebuilds, skipped steps are no-ops.
RUN /opt/gha/build/run-step.sh 00-base       "$FLAVOR"
RUN /opt/gha/build/run-step.sh 10-git        "$FLAVOR"
RUN /opt/gha/build/run-step.sh 20-docker     "$FLAVOR"
RUN /opt/gha/build/run-step.sh 30-python     "$FLAVOR"
RUN NODE_MAJOR="$NODE_MAJOR" /opt/gha/build/run-step.sh 31-node "$FLAVOR"
RUN /opt/gha/build/run-step.sh 40-cli        "$FLAVOR"
RUN /opt/gha/build/run-step.sh 50-go         "$FLAVOR"
RUN /opt/gha/build/run-step.sh 51-java       "$FLAVOR"
RUN /opt/gha/build/run-step.sh 52-dotnet     "$FLAVOR"
RUN /opt/gha/build/run-step.sh 53-rust       "$FLAVOR"
RUN /opt/gha/build/run-step.sh 54-languages  "$FLAVOR"
RUN /opt/gha/build/run-step.sh 55-powershell "$FLAVOR"
RUN /opt/gha/build/run-step.sh 56-browsers   "$FLAVOR"
RUN /opt/gha/build/run-step.sh 57-cloud      "$FLAVOR"
RUN /opt/gha/build/run-step.sh 99-finalize   "$FLAVOR"

COPY --chmod=0755 entrypoint.sh /opt/gha/entrypoint.sh
COPY --chmod=0755 hooks/ /opt/gha/hooks/

USER runner
WORKDIR /home/runner
ENTRYPOINT ["/opt/gha/entrypoint.sh"]
