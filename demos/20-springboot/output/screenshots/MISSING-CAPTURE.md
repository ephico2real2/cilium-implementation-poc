# Captures not taken yet — demos/20-springboot

petclinic (six JVMs) is scaled to zero to keep memory for the observability stack (`demos/20-springboot/scale.sh`). Captures to add after `scale.sh up` with ~3 GB of VM headroom: `https://petclinic.poc.local`, the Spring Boot 3.x Statistics dashboard (`springboot-19004`, per service), Hubble L7 for `api-gateway`, and its OTel Java agent traces in Tempo.

When they are taken, put them in this folder and link them from the demo README's **Evidence** section; then remove this file and the row in `/missing-captures.md`.
