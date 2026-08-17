// This is free and unencumbered software released into the public domain.
// See the UNLICENSE file or https://unlicense.org/ for details.

package main

import "core:strings"
import "core:testing"

@(test)
test_is_package_name :: proc(t: ^testing.T) {
    testing.expect(t, is_package_name("1password"))
    testing.expect(t, is_package_name("alsa-scarlett-gui"))
    testing.expect(t, is_package_name("azure-cli"))
    testing.expect(t, !is_package_name(""))
    testing.expect(t, !is_package_name("WARNING! Cached file /var/cache/deb-get/foo.json_extract is empty or missing."))
    testing.expect(t, !is_package_name("/var/cache/deb-get/foo.json_extract"))
    testing.expect(t, !is_package_name("[*] WARNING! Cached file"))
}

@(test)
test_parse_package_list_skips_warnings :: proc(t: ^testing.T) {
    raw := strings.clone(
        "1password\n" +
        "  [\x1b[33m*\x1b[0m] WARNING! Cached file /var/cache/deb-get/activitywatch.json_extract is empty or missing.\n" +
        "activitywatch\n" +
        "\n" +
        "  [+] Updating something\n" +
        "agena\n",
    )
    pkgs := parse_package_list_output(raw)
    defer {
        for p in pkgs {
            delete(p)
        }
        delete(pkgs)
    }
    testing.expect_value(t, len(pkgs), 3)
    if len(pkgs) == 3 {
        testing.expect_value(t, pkgs[0], "1password")
        testing.expect_value(t, pkgs[1], "activitywatch")
        testing.expect_value(t, pkgs[2], "agena")
    }
}
