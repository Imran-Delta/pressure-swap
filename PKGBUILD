# Maintainer: Imran Bin Gifary (System Delta) <imran.sdelta@gmail.com>

pkgname=pressure-swap
pkgver=1.0.0
pkgrel=1
pkgdesc="A lightweight, PSI‑aware emergency swap manager with dynamic chunking"
arch=('any')
url="https://github.com/yourusername/pressure-swap"
license=('zlib')
depends=(
    'bash'
    'systemd'
    'coreutils'
    'procps-ng'
    'util-linux'
)
optdepends=(
    'zram-generator: for automatic zram setup'
    'numfmt: human‑readable output in dashboard'
)
source=(
    "src/pressure-swap.sh"
    "src/pressure-swap-dashboard"
    "src/pressure-swap.conf"
    "systemd/pressure-swap.service"
    "systemd/pressure-swap.timer"
    "LICENSE"
)
sha256sums=(
    'SKIP'
    'SKIP'
    'SKIP'
    'SKIP'
    'SKIP'
    'SKIP'
)

package() {
    install -Dm755 "$srcdir/pressure-swap.sh" "$pkgdir/usr/local/bin/pressure-swap.sh"
    install -Dm755 "$srcdir/pressure-swap-dashboard" "$pkgdir/usr/local/bin/pressure-swap-dashboard"
    install -Dm644 "$srcdir/pressure-swap.conf" "$pkgdir/etc/pressure-swap.conf"
    install -Dm644 "$srcdir/pressure-swap.service" "$pkgdir/usr/lib/systemd/system/pressure-swap.service"
    install -Dm644 "$srcdir/pressure-swap.timer" "$pkgdir/usr/lib/systemd/system/pressure-swap.timer"
    install -Dm644 "$srcdir/LICENSE" "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}