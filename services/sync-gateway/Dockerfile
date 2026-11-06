FROM node:22-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev --ignore-scripts
COPY src ./src
USER node
ENV BIND_HOST=0.0.0.0 PORT=8788
EXPOSE 8788
CMD ["node", "src/gateway.mjs"]
