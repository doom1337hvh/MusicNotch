#!/usr/bin/perl
# Runs MusicNotch's additions to mediaremote-adapter (Adapter/*.m), which are compiled
# into MediaRemoteAdapter.framework. Like mediaremote-adapter.pl, it goes through
# /usr/bin/perl because MediaRemote only answers Apple-signed processes.
#
#   musicnotch-adapter.pl FRAMEWORK_PATH sessions [--no-artwork] [--debounce=MS]
#   musicnotch-adapter.pl FRAMEWORK_PATH send COMMAND BUNDLE_ID [PARENT_BUNDLE_ID]
#   musicnotch-adapter.pl FRAMEWORK_PATH clear-override
#
# COMMAND is a MediaRemote command number, or seek=SECONDS to jump to a position.
# `send` and `clear-override` use MUSICNOTCH_OVERRIDE_MARKER, set by MusicNotch.
use strict;
use warnings;
use DynaLoader;
use File::Basename;

my $usage = "Usage: musicnotch-adapter.pl FRAMEWORK_PATH (sessions [--no-artwork] [--debounce=MS]"
  . " | send COMMAND BUNDLE_ID [PARENT_BUNDLE_ID] | clear-override)\n";
my ($framework_path, $command, @args) = @ARGV;
die $usage unless defined $command;

(my $name = basename($framework_path)) =~ s/\.framework$//
  or die "Not a framework: $framework_path\n";

my $symbol_name;
if ($command eq 'sessions') {
  for my $option (@args) {
    if ($option eq '--no-artwork') {
      $ENV{MUSICNOTCH_NO_ARTWORK} = '1';
    }
    elsif ($option =~ /^--debounce=(\d+)$/) {
      $ENV{MUSICNOTCH_DEBOUNCE_MS} = $1;
    }
    else {
      die "Unknown option: $option\n";
    }
  }
  $symbol_name = 'musicnotch_sessions';
}
elsif ($command eq 'send') {
  my ($media_command, $bundle_id, $parent_id) = @args;
  die $usage unless defined $bundle_id && defined $media_command;
  if ($media_command =~ /^\d+$/) {
    $ENV{MUSICNOTCH_COMMAND} = $media_command;
  }
  elsif ($media_command =~ /^seek=(\d+(?:\.\d+)?)$/) {
    $ENV{MUSICNOTCH_SEEK} = $1;
  }
  else {
    die $usage;
  }
  $ENV{MUSICNOTCH_TARGET} = $bundle_id;
  $ENV{MUSICNOTCH_TARGET_PARENT} = $parent_id if defined $parent_id;
  $symbol_name = 'musicnotch_send';
}
elsif ($command eq 'clear-override') {
  $symbol_name = 'musicnotch_clear_override';
}
else {
  die $usage;
}

my $handle = DynaLoader::dl_load_file("$framework_path/$name", 0)
  or die "Failed to load $framework_path\n";
my $symbol = DynaLoader::dl_find_symbol($handle, $symbol_name)
  or die "$symbol_name not found in $framework_path\n";
DynaLoader::dl_install_xsub('main::run', $symbol);
main::run();
