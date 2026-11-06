FROM node:24-bookworm-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts
COPY src ./src
COPY public ./public
RUN mkdir /data && chown node:node /data
USER node
ENV SHARE_DATA_DIRECTORY=/data HOST=0.0.0.0 PORT=8787
EXPOSE 8787
CMD ["node", "src/main.ts"]
