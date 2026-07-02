# Maintainer: Imran Bin Gifary (System Delta) <imran.sdelta@gmail.com>

pkgname=pressure-swap
pkgver=1.0.0
pkgrel=1
pkgdesc="A lightweight, PSI‑aware emergency swap manager with dynamic chunking"
arch=('any')
url="https://github.com/Imran-Delta/pressure-swap"
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
    '87ac885399d2dcdc2d1fe14e697e164a14d9dcd404811ba6bf0cd2b7caf2a279'
    '5e0d95a85d951af09b39e2ef119657ca4f1742838caf139927bc6cb26c0c6a33'
    '450594bfee3728dd08ec1422b07c92dddce0516387e6ea68387161cb56475124'
    '945d853638df484a30e149bc75f1cbae8eda3d67931892062f02faf56576f5ca'
    'd7a12324310ed632e690b1e058a6b943902e52c89325cf877291894a1ebfe3c2'
    '4c374d64de1140806c3f8e3eeb6bed344ee79cafe1ee3c16809712abee6dc266'
)

package() {
    install -Dm755 "$srcdir/pressure-swap.sh" "$pkgdir/usr/local/bin/pressure-swap.sh"
    install -Dm755 "$srcdir/pressure-swap-dashboard" "$pkgdir/usr/local/bin/pressure-swap-dashboard"
    install -Dm644 "$srcdir/pressure-swap.conf" "$pkgdir/etc/pressure-swap.conf"
    install -Dm644 "$srcdir/pressure-swap.service" "$pkgdir/usr/lib/systemd/system/pressure-swap.service"
    install -Dm644 "$srcdir/pressure-swap.timer" "$pkgdir/usr/lib/systemd/system/pressure-swap.timer"
    install -Dm644 "$srcdir/LICENSE" "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}