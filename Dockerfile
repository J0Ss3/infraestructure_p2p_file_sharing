FROM node:22-bookworm-slim AS build
ARG APP_REF=main
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 --branch ${APP_REF} https://github.com/J0Ss3/p2p_file_sharing.git .
RUN npm run install:all && npm run build

FROM node:22-bookworm-slim
WORKDIR /app
COPY --from=build /src/server/dist          ./server/dist
COPY --from=build /src/server/node_modules  ./server/node_modules
COPY --from=build /src/client/dist          ./client/dist
ENV PORT=3000
EXPOSE 3000
CMD ["node", "server/dist/index.js"]
