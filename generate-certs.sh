#!/bin/bash
CA_NAME="${CA_NAME:-host.internal}"
CERTS_PATH="${CERTS_PATH:-/etc/certs}"

generate-cert() {
    declare cert_path="$1" cert_name="$2" cn="$3" expiry_seconds="$4"
    local expiry_hours=$(($expiry_seconds / 3600))
    certstrap \
        --depot-path="." \
        init \
        --passphrase="" \
        --common-name "$CA_NAME"

    certstrap \
        --depot-path="." \
        request-cert \
        --passphrase="" \
        --common-name "$cn"

    certstrap \
        --depot-path="." \
        sign \
        --passphrase="" \
        --expires "$expiry_hours hours" \
        --CA "$CA_NAME" \
        "$cn"

    cat "./${cn}.key" "./${cn}.crt" > "/${cert_path}/${cert_name}.pem"
    mv "./${cn}.crt" "/${cert_path}/${cert_name}.crt"
    mv "./${cn}.key" "/${cert_path}/${cert_name}.key"
}

main() {
    declare purpose="$1" cn="$2" expiry_seconds="$3"
    local cert_name="${purpose}-$cn"
    local cert_path="$CERTS_PATH"

        local tmp="$(mktemp -d /tmp/generate-cert.XXX)"
        trap "rm -rf $tmp" INT TERM EXIT
        cd "$tmp"
        generate-cert "$cert_path" "$cert_name" "$cn" "$expiry_seconds"
        echo "Generated new certificate"
}

main "$@"
