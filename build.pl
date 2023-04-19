# Copyright 2023 alex@staticlibs.net
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

use strict;
use warnings;
use Archive::Extract;
use Cwd qw(abs_path getcwd);
use Digest::file qw(digest_file_hex);
use File::Basename qw(basename dirname);
use File::Copy::Recursive qw(fcopy dircopy);
use File::Path qw(make_path remove_tree);
use File::Slurp qw(edit_file read_file write_file);
use File::Spec::Functions qw(abs2rel catfile);
use JSON qw(decode_json);
use LWP::Simple qw(getstore);
use Text::Patch qw(patch);

my $root_dir = dirname(abs_path(__FILE__));

sub read_config {
  my $config_file = catfile($root_dir, "config.json");
  if (! -f $config_file) {
    $config_file = catfile($root_dir, "config-default.json");
  }
  my $config_json = read_file($config_file);
  my $config = decode_json($config_json);
  return $config;
}

sub ensure_dir_empty {
  my $dir = shift;
  if (-d $dir) {
    remove_tree($dir) or die("$!");
  }
  make_path($dir) or die("$!");
}

sub file_sha256sum {
  my $file_path = shift;
  my $sha256 = digest_file_hex($file_path, "SHA-256");
  my $file_name = basename($file_path);
  my $contents = "$sha256  $file_name";
  write_file("$file_path.sha256", $contents) or die("$!");
  print("$contents\n");
}

sub get_sources {
  my $cf = shift;

  my $src_dir = catfile($root_dir, "src");
  ensure_dir_empty($src_dir);
  my $filename = basename($cf->{tarball}->{url});
  my $filepath = catfile($src_dir, $filename);
  if (${cf}->{tarball}->{localPath}) {
    fcopy(${cf}->{tarball}->{localPath}, $filepath) or die("$!");
  } else {
    print("Downloading tarball, url: [$cf->{tarball}->{url}]\n");
    getstore($cf->{tarball}->{url}, $filepath) or die("$!");
  }

  my $sha256 = digest_file_hex($filepath, "SHA-256");
  if (!($sha256 eq $cf->{tarball}->{sha256})) {
    die("Tarball sha256 sum mismatch, file: [$filename]," .
        " expected: [$cf->{tarball}->{sha256}], actual: [$sha256]");
  }

  print("Unpacking file: [$filename]\n");
  my $ae = Archive::Extract->new(archive => $filepath);
  $ae->extract(to => $src_dir) or die("$!");
  my $root_dir_name = $ae->files->[0];
  return catfile($src_dir, $root_dir_name);
}

sub prepare_install_dir {
  my $cf = shift;
  my $src_dir = shift;
  my $out_dir = catfile($root_dir, "out");
  ensure_dir_empty($out_dir);
  my $name = basename($src_dir);
  my $install_dir = catfile($out_dir, $name);
  make_path($install_dir) or die("$!");
  return $install_dir;
}

sub apply_patches {
  my $cf = shift;
  my $src_dir = shift;

  for my $p (@{$cf->{patches}}) {
    print("Applying patch: [$p->{patch}] to file: [$p->{file}]\n");
    my $patch = read_file(catfile($root_dir, $p->{patch})) or die("$!");
    my $file_path = catfile($src_dir, $p->{file});
    my $unpatched = read_file($file_path) or die("$!");
    my $patched = patch($unpatched, $patch, STYLE => "Unified");
    fcopy($file_path, "$file_path.orig") or die("$!");
    write_file($file_path, $patched) or die("$!");
  }
}

sub system_msys2 {
  my $dir = shift;
  my $cmd = shift;

  my $msys_dir = $ENV{MSYS2_HOME};
  if (!$msys_dir) {
    $msys_dir = "c:/msys64";
  }

  my $dir_forward = $dir =~ s/\\/\//gr;
  my $cwd = getcwd();
  my $msystem = $ENV{MSYSTEM};
  if (!$msystem) {
      $ENV{MSYSTEM} = "MINGW64";
  }

  chdir($dir);
  print("$cmd\n");
  my $res = system("$msys_dir/usr/bin/bash.exe -lc 'cd $dir_forward && $cmd'");

  chdir($cwd);
  $ENV{MSYSTEM} = $msystem;
  return $res;
}

sub setup_env {
  0 == system_msys2(".", "pacman --noconfirm -Sy pacman") or die("$!");
  0 == system_msys2(".", "pacman --noconfirm -Syuu") or die("$!");
  0 == system_msys2(".", "pacman --noconfirm -Syuu") or die("$!");
  0 == system_msys2(".", "pacman --noconfirm -Sy mingw-w64-x86_64-gcc make") or die("$!");
}

sub configure {
  my $cf = shift;
  my $src_dir = shift;
  my $install_dir = shift;

  my $install_dir_forward = $install_dir =~ s/\\/\//gr;
  my $mingw_chost = "x86_64-w64-mingw32";
  my $cmd = "./configure";
  $cmd .= " CFLAGS=-static";
  $cmd .= " --host=$mingw_chost";
  $cmd .= " --build=$mingw_chost";
  $cmd .= " --target=$mingw_chost";
  $cmd .= " --prefix=$install_dir_forward";
  $cmd .= " --disable-dependency-tracking";
  0 == system_msys2($src_dir, $cmd) or die("$!");
}

sub make {
  my $cf = shift;
  my $src_dir = shift;

  # static libiconv and libintl
  my $makefile = catfile($src_dir, "src", "Makefile");
  edit_file(sub { s/\/libiconv.dll.a/\/libiconv.a/g }, $makefile);
  edit_file(sub { s/\/libintl.dll.a/\/libintl.a/g }, $makefile);
  0 == system_msys2($src_dir, "make WINDOWS_STAT_INODES=1") or die("$!");
}

sub make_check {
  my $cf = shift;
  my $src_dir = shift;

  my $init_sh = catfile($src_dir, "tests", "init.sh");
  my $from = 'case \$perms in drwx--\[-S\]---\*';
  my $to = 'case $perms in drwx*';
  edit_file(sub { s/$from/$to/ }, $init_sh);

  my $tests_dir = catfile($src_dir, "tests");
  my @tests = (
    "basic",
    "bignum",
    "brief-vs-stat-zero-kernel-lies",
    "colliding-file-names",
    "diff3",
    "excess-slash",
    "function-line-vs-leading-space",
    "ignore-matching-lines",
    "label-vs-func",
    "new-file",
    "no-newline-at-eof",
    "stdin",
    "strcoll-0-names"
    );
  for my $t (@tests) {
    print("Running test: [$t]");
    0 == system_msys2($tests_dir, "make check TESTS=$t\n") or die("$!");
  }
}

sub make_install {
  my $cf = shift;
  my $src_dir = shift;
  my $install_dir = shift;

  0 == system_msys2($src_dir, "make install") or die("$!");
  my $bin_dir = catfile($install_dir, "bin");
  my @exe_list = <$bin_dir/*.exe>;
  for my $exe_path (@exe_list) {
    file_sha256sum($exe_path);
  }
}

my $config = read_config();
my $src_dir = get_sources($config);
my $install_dir = prepare_install_dir($config, $src_dir);
apply_patches($config, $src_dir);
setup_env();
configure($config, $src_dir, $install_dir);
make($config, $src_dir);
make_check($config, $src_dir);
make_install($config, $src_dir, $install_dir);
