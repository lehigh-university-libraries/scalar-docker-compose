#!/bin/sh
# Run inside the Scalar container; never traverse the image-owned code symlinks.
set -eu
case "${1:-check}" in
  check)
    if [ ! -r /opt/scalar ] || [ ! -w /opt/scalar ] || [ ! -x /opt/scalar ]; then
      echo 'The PHP-FPM user cannot access the book-data root.' >&2
      exit 1
    fi
    inaccessible=$(find /opt/scalar -mindepth 1 \( \
      -type d \( ! -exec test -r {} \; -o ! -exec test -w {} \; -o ! -exec test -x {} \; \) \
      -o -type f \( ! -exec test -r {} \; -o ! -exec test -w {} \; \) \) -print)
    if [ -n "$inaccessible" ]; then
      printf 'Book content is inaccessible to the PHP-FPM user:\n%s\n' "$inaccessible" >&2
      exit 1
    fi
    echo 'Book-data permissions are writable by the PHP-FPM user.'
    ;;
  fix)
    # This is an explicit operation on the staged books-only mount. Do not
    # follow symlinks into bundled code or other host locations.
    find /opt/scalar -mindepth 1 \( -type d -o -type f \) -exec chown nginx:nginx {} +
    find /opt/scalar -mindepth 1 -type d -exec chmod u+rwx {} +
    find /opt/scalar -mindepth 1 -type f -exec chmod u+rw {} +
    chown root:nginx /opt/scalar
    chmod 1775 /opt/scalar
    ;;
  *) echo 'Usage: permissions.sh check|fix' >&2; exit 1 ;;
esac
