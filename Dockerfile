FROM registry.redhat.io/jboss-webserver-6/jws60-openjdk17-openshift-rhel8 as builder
USER ROOT
COPY --chown=1001:0 . /tmp/src
USER 1001
RUN /usr/local/s2i/assemble

FROM registry.redhat.io/jboss-webserver-6/jws60-openjdk17-openshift-rhel8
COPY --from=builder /deployments/ROOT.war /deployments/
