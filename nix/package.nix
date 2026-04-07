{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule rec {
  pname = "ziti";
  version = "1.6.14";

  src = fetchFromGitHub {
    owner = "openziti";
    repo = "ziti";
    rev = "v${version}";
    hash = "sha256-wZ7yAR/LHfjY7qEXBnpzwIvbf8OoLvUHkEBlcHunYcg=";
  };

  vendorHash = "sha256-hBD4uM5Y2TyyvpJgpNPKCc/FtDu0jPkz6Tk4RhmecTQ=";

  subPackages = [ "ziti" ];

  tags = [ "pkcs11" ];

  ldflags = [
    "-s"
    "-w"
    "-X github.com/openziti/ziti/common/version.Version=v${version}"
    "-X github.com/openziti/ziti/common/version.Revision=nix"
    "-X github.com/openziti/ziti/common/version.BuildDate=1970-01-01T00:00:00Z"
  ];

  # Tests require network access and a running controller.
  doCheck = false;

  meta = {
    description = "OpenZiti — programmable zero trust networking";
    homepage = "https://openziti.io";
    license = lib.licenses.asl20;
    mainProgram = "ziti";
    platforms = lib.platforms.linux;
  };
}
