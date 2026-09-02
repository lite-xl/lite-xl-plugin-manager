{
  inputs = {
    nixpkgs-unstable.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    nixpkgs-25-11.url = "github:nixos/nixpkgs?ref=nixos-25.11";
  };
  outputs = { nixpkgs-unstable, nixpkgs-25-11, ... }: let 
    lpmVersions = { pkgs }: {
      continuous = pkgs.callPackage ({
        stdenv,
        fetchzip,
        ...
      }: stdenv.mkDerivation {
        pname = "lite-xl-plugin-manager";
        version = "continuous";
        src = fetchzip {
          url = "https://github.com/lite-xl/lite-xl-plugin-manager/archive/refs/tags/continuous.zip";
          sha256 = "sha256-ZA7rNZbOVNTZjWUm8Em88GQPpsuJ+wevnoMXpaHJn/g=";      
        };
      });
      v147 = pkgs.callPackage ({
        stdenv,
        fetchzip,
        ...
      }: stdenv.mkDerivation {
        pname = "lite-xl-plugin-manager";
        version = "1.4.7";
        src = fetchzip {
          url = "https://github.com/lite-xl/lite-xl-plugin-manager/archive/refs/tags/v1.4.7.zip";
          sha256 = "sha256-16c12fcc5afcdnja6vvacic0r9n46zaiggr8nm00zni367z9wvsq=";      
        };
      }) {};
    };

    nixpkgs = system: {
      unstable = lpmVersions { 
        pkgs = nixpkgs-unstable.legacyPackages."${system}";
      };
      nix-25-11 = lpmVersions { 
        pkgs = nixpkgs-25-11.legacyPackages."${system}";
      };
      default = nixpkgs-25-11.legacyPackages."${system}".callPackage ({
        stdenv,
        fetchzip,
        ...
      }: stdenv.mkDerivation {
        pname = "lite-xl-plugin-manager";
        version = "continuous";
        src = fetchzip {
          url = "https://github.com/lite-xl/lite-xl-plugin-manager/archive/refs/tags/continuous.zip";
          sha256 = "sha256-ZA7rNZbOVNTZjWUm8Em88GQPpsuJ+wevnoMXpaHJn/g=";      
        };
      }) {};
    };
  in {
    packages = {
      "aarch64-android" = ( nixpkgs "aarch64-android" );
      "aarch64-darwin" = ( nixpkgs "aarch64-darwin" );
      "aarch64-linux" = ( nixpkgs "aarch64-linux" );
      "arm-android" = ( nixpkgs "arm-android" );
      "riscv64-linux" = ( nixpkgs "riscv64-linux" );
      "x86-android" = ( nixpkgs "x86-android" );
      "x86_64-android" = ( nixpkgs "x86_64-android" );
      "x86_64-darwin" = ( nixpkgs "x86_64-darwin" );
      "x86_64-linux" = ( nixpkgs "x86_64-linux" );
    };
  };
}
