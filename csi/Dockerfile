ARG BASE_IMAGE
FROM ${BASE_IMAGE}

COPY bin/zettide /usr/local/bin/zettide
COPY bin/zettide-csi-node /usr/local/bin/zettide-csi-node
COPY bin/fusermount3 /usr/bin/fusermount3
COPY bin/libfuse3.so.4 /usr/lib64/libfuse3.so.4

ENTRYPOINT ["/usr/local/bin/zettide-csi-node"]
