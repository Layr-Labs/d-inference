FROM node:22-alpine
RUN apk add --no-cache curl coreutils
WORKDIR /harness
COPY gen-manifests.mjs stub-coordinator.mjs seed-bucket.sh verify.mjs ./
CMD ["node", "stub-coordinator.mjs"]
