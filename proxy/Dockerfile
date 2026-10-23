FROM alpine:3.22

RUN apk add --no-cache squid

COPY squid.conf /etc/squid/squid.conf

EXPOSE 3128

# Start as `squid` (not root) so it owns the container's stdout/stderr for logging
USER squid

# -N keeps squid in the foreground so the container lives as long as it does
CMD ["squid", "-N", "-f", "/etc/squid/squid.conf"]
