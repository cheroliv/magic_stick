#!/bin/sh
# Factorisation de la detection architecture
# Sourcer avec : . /usr/local/lib/magic-stick/arch.sh
#
# Usage: get_arch_suffix <format>
# Formats supportes:
#   rust       -> x86_64-unknown-linux-gnu / aarch64-unknown-linux-gnu
#   musl       -> x86_64-unknown-linux-musl / aarch64-unknown-linux-musl
#   lazygit    -> Linux_x86_64 / Linux_arm64
#   gh         -> amd64 / arm64
#   opencode   -> x86_64 / arm64
#   vscode     -> x64 / arm64
#   generic    -> x86_64 / aarch64

get_arch_suffix() {
    _fmt="${1:-generic}"
    _arch="$(uname -m)"
    case "${_fmt}" in
        rust)
            case "${_arch}" in
                x86_64)  printf '%s' "x86_64-unknown-linux-gnu" ;;
                aarch64) printf '%s' "aarch64-unknown-linux-gnu" ;;
                *)       return 1 ;;
            esac
            ;;
        musl|just)
            case "${_arch}" in
                x86_64)  printf '%s' "x86_64-unknown-linux-musl" ;;
                aarch64) printf '%s' "aarch64-unknown-linux-musl" ;;
                *)       return 1 ;;
            esac
            ;;
        lazygit)
            case "${_arch}" in
                x86_64)  printf '%s' "Linux_x86_64" ;;
                aarch64) printf '%s' "Linux_arm64" ;;
                *)       return 1 ;;
            esac
            ;;
        gh)
            case "${_arch}" in
                x86_64)  printf '%s' "amd64" ;;
                aarch64) printf '%s' "arm64" ;;
                *)       return 1 ;;
            esac
            ;;
        opencode)
            case "${_arch}" in
                x86_64)  printf '%s' "x86_64" ;;
                aarch64) printf '%s' "arm64" ;;
                *)       return 1 ;;
            esac
            ;;
        vscode)
            case "${_arch}" in
                x86_64)  printf '%s' "x64" ;;
                aarch64) printf '%s' "arm64" ;;
                *)       return 1 ;;
            esac
            ;;
        generic|*)
            case "${_arch}" in
                x86_64)  printf '%s' "x86_64" ;;
                aarch64) printf '%s' "aarch64" ;;
                *)       return 1 ;;
            esac
            ;;
    esac
}
