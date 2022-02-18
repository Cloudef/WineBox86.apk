{ wineVersion ? "6.0-rc6" }:

rec {
   local = fetchTarball "https://github.com/Cloudef/nixpkgs/archive/android-prebuilt.tar.gz";
   pkgs = import local { config = { android_sdk.accept_license = true; }; };
   android-i686 = import local {
     crossSystem = {
       config = "i686-unknown-linux-android";
       rustc.config = "i686-linux-android";
       sdkVer = "28";
       ndkVer = "23b";
       useAndroidPrebuilt = true;
     };
     config = {
       android_sdk.accept_license = true;
       packageOverrides = this:
       let isAndroid = this.hostPlatform.isAndroid;
       in {
         freetype = this.freetype.overrideAttrs (oldAttrs:
         this.lib.optionalAttrs isAndroid {
           nativeBuildInputs = [];
           postInstall = "";
         });
         gnutls = this.gnutls.overrideAttrs (oldAttrs:
         this.lib.optionalAttrs isAndroid {
           buildInputs = [ this.gmp ];
           outputs = [ "dev" "out" ];
           hardeningDisable = [ "fortify" ];
           configureFlags = oldAttrs.configureFlags ++ [
             "--with-default-trust-store-pkcs11="
             "--without-p11-kit"
             "--without-idn"
             "--with-included-libtasn1"
             "--with-included-unistring"
             "-disable-cxx"
             "--disable-maintainer-mode"
             "--disable-doc"
             "--disable-tools"
             "--disable-tests"
           ];
         });
       };
     };
   };

   src = fetchGit {
     url = "git://source.winehq.org/git/wine.git";
     ref = "refs/tags/wine-${wineVersion}";
   };

   wine-tools = pkgs.stdenv.mkDerivation {
     name = "wine-tools";
     enableParallelBuilding = true;
     inherit src;
     nativeBuildInputs = with pkgs; [
       flex
       bison
       pkg-config
       freetype
       pkgsCross.mingwW64.buildPackages.gcc
     ];
     configureFlags = [ "--enable-win64" "--disable-win16" "--without-x" ];
     buildPhase = "make tools/all $(cat Makefile | grep 'tools/.*/all:' | sed 's/:.*//' | tr '\\n' ' ')";
     installPhase = ''
           mkdir -p $out; cp -r tools $out/
           # make tools/all $(cat Makefile | grep 'tools/.*/install-dev:' | sed 's/:.*//' | tr '\n' ' ')
           # (cd $out; ln -s bin tools)
     '';
   };

   android-sdk = (pkgs.androidenv.composeAndroidPackages {
     platformVersions = [ "25" ];
     buildToolsVersions = [ "25.0.3" ];
   }).androidsdk;

   gradle-3 = pkgs.stdenv.mkDerivation rec {
     name = "gradle-3.5.1";
     src = pkgs.fetchurl {
       url = "https://services.gradle.org/distributions/${name}-bin.zip";
       hash = "sha256-jc419S1Me0pJRt9zqigw52unFIhQdT2LXpTF3DJc7vg=";
     };
     nativeBuildInputs = [ pkgs.unzip ];
     installPhase = "mkdir $out; cp -r bin lib $out";
   };

   wine-gradle-deps = pkgs.stdenv.mkDerivation {
     name = "wine-gradle-deps";
     inherit src;
     nativeBuildInputs = with pkgs; [
       android-sdk
       jdk8
       gradle-3
       perl
       librsvg # rsvg-convert
     ];
     ANDROID_HOME = "${android-sdk}/libexec/android-sdk";
     ANDROID_SDK_ROOT = "${android-sdk}/libexec/android-sdk";
     patchPhase = ''
       sed "s/@PACKAGE_VERSION@/7.0-rc1/g" dlls/wineandroid.drv/build.gradle.in > dlls/wineandroid.drv/build.gradle
     '';
     dontConfigure = true;
     buildPhase = ''
       export GRADLE_USER_HOME="$(mktemp -d)"
       srcdir="$PWD"
       (cd dlls/wineandroid.drv && gradle --no-daemon -Psrcdir="$srcdir" assembleDebug)
     '';
     installPhase = ''
       find "$GRADLE_USER_HOME"/caches/modules-2 -type f -regex '.*\.\(jar\|pom\)' \
          | perl -pe 's#(.*/([^/]+)/([^/]+)/([^/]+)/[0-9a-f]{30,40}/([^/\s]+))$# ($x = $2) =~ tr|\.|/|; "install -Dm444 $1 \$out/$x/$3/$4/$5" #e' \
          | sh
     '';
     outputHashMode = "recursive";
     outputHash = "sha256-jKykmhtp1F5rWupr5P7q/eh91FPPeffFJY/+bbPlUWg=";
   };

   wine-i686 = android-i686.stdenv.mkDerivation {
     name = "wine";
     enableParallelBuilding = true;
     inherit src;
     buildInputs = with android-i686; [
       freetype
       zlib
       bzip2
       libpng
       libjpeg_original
       lcms2
       libtiff
       libxml2
       libxslt
       gmp
       nettle
       gnutls
     ];
     nativeBuildInputs = with pkgs; [
       flex
       bison
       pkg-config
       pkgsCross.mingw32.buildPackages.gcc
       wine-tools.out
       # android deps
       wine-gradle-deps
       android-sdk
       gradle-3
       jdk8
       librsvg # rsvg-convert
     ];
     ANDROID_HOME = "${android-sdk}/libexec/android-sdk";
     ANDROID_SDK_ROOT = "${android-sdk}/libexec/android-sdk";
     patchPhase = ''
      # Point gradle to offline repo
      sed -i "s#jcenter()#maven { url '${wine-gradle-deps}' }#g" dlls/wineandroid.drv/build.gradle.in
     '';
     configureFlags = [
       # force linkage to shared libc
       "LDFLAGS=-L${android-i686.stdenv.cc.libc}/lib"
       "--with-wine-tools=${wine-tools.out}"
       "--disable-win16"
       "--without-x"
     ];
     dontFixup = true;
   };
 }
