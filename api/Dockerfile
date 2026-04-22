FROM dart:stable AS build

WORKDIR /app
COPY pubspec.yaml .
RUN dart pub get

COPY . .
RUN dart pub get
RUN dart compile exe bin/server.dart -o /app/build/reachtrail_api

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /usr/sbin/nologin reachtrail
WORKDIR /app
COPY --from=build /app/build/reachtrail_api /app/reachtrail_api

RUN mkdir -p /app/data && chown -R reachtrail:reachtrail /app
USER reachtrail

EXPOSE 8080
CMD ["/app/reachtrail_api"]
