ARG GLEAM_VERSION=v1.16.0

# Build stage - compile the application
FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-erlang-alpine AS builder

RUN apk add --no-cache git gcc sqlite sqlite-dev build-base inotify-tools

# Add project code
COPY ./shared /build/shared
COPY ./client /build/client
COPY ./server /build/server
COPY ./vendor /build/vendor
RUN rm /build/server/database.db

# Install dependencies for all projects
RUN cd /build/shared && gleam deps download
RUN cd /build/client && gleam deps download
RUN cd /build/server && gleam deps download

# Compile the client code and output to server's static directory
RUN cd /build/client \
  && gleam run -m lustre/dev build banana_split_client_prod --minify --outdir=../server/priv/static

# Compile the server code
RUN cd /build/server \
  && gleam export erlang-shipment

RUN cd /build/server \
	&& gleam run -m db/create

# Runtime stage - slim image with only what's needed to run
FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-erlang-alpine

# Copy the compiled server code from the builder stage
COPY --from=builder /build/server/build/erlang-shipment /app
COPY --from=builder /build/server/database.db /app/database.db

# Set up the entrypoint
WORKDIR /app
RUN echo -e '#!/bin/sh\nexec ./entrypoint.sh "$@"' > ./start.sh \
  && chmod +x ./start.sh

# Set environment variables
ENV HOST=0.0.0.0
ENV PORT=8080

# Expose the port the server will run on
EXPOSE $PORT

# Run the server
CMD ["./start.sh", "run"]
