# FROM openjdk:11-jre
# RUN apt-get update && apt-get upgrade --yes && apt-get install openssl --yes && apt-get clean autoclean && apt-get autoremove --yes && rm -rf /var/lib/{apt,dpkg,cache,log}/

# https://hub.docker.com/_/openjdk?tab=tags&page=1&name=18
FROM  openjdk:18.0.1-oracle

LABEL maintainer="AndriyKalashnykov@gmail.com"

RUN microdnf install openssl wget

RUN mkdir -p /ldap/ldif
WORKDIR /ldap

# RUN wget https://github.com/AndriyKalashnykov/ldap-server/releases/download/2021-04-07/ldap-server.jar

# followint line skips caching of downloaded ldap-server.jar
ADD "https://www.random.org/cgi-bin/randbyte?nbytes=10&format=h" skipcache
RUN wget --timeout=600 https://github.com/AndriyKalashnykov/ldap-server/releases/download/latest/ldap-server.jar

RUN useradd -r -M -d  /ldap ldap && \
    chown -R ldap:ldap /ldap && \
    chown -h ldap:ldap /ldap

USER ldap

# COPY ./ldif/users.ldif /ldap/ldif/users.ldif

EXPOSE 10389

# so we can mount any directory to `/ldap/ldif/` directoy to import LDIFs
# i.e.
# volumes:
#   - ./ldif:/ldap/ldif 
CMD ["java","-jar","ldap-server.jar", "/ldap/ldif/"]
