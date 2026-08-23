# Maintainer: K-Sugar <dd.untainted482@passmail.net>
pkgname=discord-ducking
pkgver=1.0.1
pkgrel=1
pkgdesc="Discord's 'Attenuation (when others speak)', missing on Linux, for PipeWire"
arch=('any')
url="https://github.com/K-Sugar/discord-ducking"
license=('MIT')
depends=('bash' 'python' 'pipewire' 'pipewire-pulse' 'wireplumber' 'easyeffects' 'lsp-plugins-lv2')
# python-numpy is deliberately NOT a hard dependency: it is 49 MiB (plus cblas
# and lapack) for a 50 KB package. The mandatory calibration tool
# (`discord-ducking measure`) is stdlib-only for exactly this reason; only the
# optional two-tone proof needs numpy for its FFT.
optdepends=('python-numpy: required by "discord-ducking test" only (two-tone FFT proof)'
            'qpwgraph: visual inspection of the audio graph'
            'pavucontrol: manual stream routing')
install="${pkgname}.install"

# Builds from this working tree, so it needs no remote and no tarball:
#   cd discord-ducking && makepkg -si
#
# To publish on the AUR later, replace the empty source=() and the `cd "$startdir"`
# in package() with:
#   source=("$pkgname-$pkgver.tar.gz::$url/archive/v$pkgver.tar.gz")
#   sha256sums=('SKIP')   # then: updpkgsums
#   cd "$srcdir/$pkgname-$pkgver"
source=()
sha256sums=()

package() {
  cd "$startdir"

  # Nothing is compiled: this is config plus shell. The package installs
  # templates and tooling system-wide; per-user deployment into ~/.config is
  # done by `discord-ducking install`, since pacman must not write to $HOME.

  install -Dm755 bin/discord-ducking "$pkgdir/usr/bin/discord-ducking"

  local f
  for f in scripts/*.sh; do
    install -Dm755 "$f" "$pkgdir/usr/share/$pkgname/$f"
  done

  while IFS= read -r -d '' f; do
    install -Dm644 "$f" "$pkgdir/usr/share/$pkgname/$f"
  done < <(find config -type f -print0)

  install -Dm644 README.md      "$pkgdir/usr/share/doc/$pkgname/README.md"
  install -Dm644 docs/DESIGN.md "$pkgdir/usr/share/doc/$pkgname/DESIGN.md"
  install -Dm644 docs/BUILD-LOG.md "$pkgdir/usr/share/doc/$pkgname/BUILD-LOG.md"
  # scripts resolve docs relative to /usr/share/discord-ducking
  install -Dm644 docs/DESIGN.md "$pkgdir/usr/share/$pkgname/docs/DESIGN.md"

  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}
