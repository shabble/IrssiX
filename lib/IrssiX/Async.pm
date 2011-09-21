package IrssiX::Async;

use warnings;
use strict;

our $VERSION = '0.04';

use POSIX ();
use Irssi ();

use again 'IrssiX::Util' => qw(run_from_package);

use Exporter qw(import);
our @EXPORT_OK = qw(
	fork_off
);

sub _register_handler_in {
	my ($pkg) = @_;
	my $prefix = '?__irssix_async_';
	my $name = $prefix . 'pidwait';
	my $full_name = $pkg . '::' . $name;
	my $ref = do { no strict 'refs'; \%$full_name and \*$full_name };
	unless (*$ref{CODE}) {
		my $pending = *$ref{HASH};
		*$ref = sub {
			my ($dead_pid, $status) = @_;
			my $entry = delete $pending->{$dead_pid} or return;
			$entry->{done}($entry->{out_data}, $entry->{err_data}, $status);
		};
		run_from_package $pkg, \&Irssi::signal_add, 'pidwait', $name;
	}
	$ref
}

sub fork_off {
	my ($in_data, $body, $done) = @_;

	pipe my $in_r,  my $in_w  or return $done->('', "pipe(): $!\n", undef);
	pipe my $out_r, my $out_w or return $done->('', "pipe(): $!\n", undef);
	pipe my $err_r, my $err_w or return $done->('', "pipe(): $!\n", undef);
	
	defined(my $pid = fork) or return $done->('', "fork(): $!\n", undef);

	if ($pid) {
		close $in_r;
		close $out_w;
		close $err_w;

		my $caller = caller;

		my $symbol_ref = _register_handler_in $caller;
		my $pending = *$symbol_ref{HASH};
		my $entry = $pending->{$pid} = {
			out_data => '',
			err_data => '',
			done => $done,
		};

		my $tag_in;
		$tag_in = run_from_package $caller, \&Irssi::input_add, fileno($in_w), Irssi::INPUT_WRITE, sub {
			my $n;
			if ($in_data eq '' || !defined($n = syswrite $in_w, $in_data)) {
				run_from_package $caller, \&Irssi::input_remove, $tag_in;
				close $in_w;
				return;
			}
			substr $in_data, 0, $n, '';
		}, undef;

		my $tag_out;
		$tag_out = run_from_package $caller, \&Irssi::input_add, fileno($out_r), Irssi::INPUT_READ, sub {
			my $buf;
			if (!sysread $out_r, $buf, 1024) {
				run_from_package $caller, \&Irssi::input_remove, $tag_out;
				close $out_r;
			}
			$entry->{out_data} .= $buf;
		}, undef;

		my $tag_err;
		$tag_err = run_from_package $caller, \&Irssi::input_add, fileno($err_r), Irssi::INPUT_READ, sub {
			my $buf;
			if (!sysread $err_r, $buf, 1024) {
				run_from_package $caller, \&Irssi::input_remove, $tag_err;
				close $err_r;
			}
			$entry->{err_data} .= $buf;
		}, undef;

		run_from_package $caller, \&Irssi::pidwait_add, $pid;
	} else {
		close $in_w;
		close $out_r;
		close $err_r;

		open STDIN, '<&', $in_r;
		open STDOUT, '>&', $out_w;
		open STDERR, '>&', $err_w;
		select STDOUT;

		close $in_r;
		close $out_w;
		close $err_w;

		POSIX::close $_ for 3 .. 255;

		eval { $body->(); 1 } or print STDERR $@;

		close STDOUT;
		close STDERR;

		POSIX::_exit 0;
	}
}

1

__END__

=head1 NAME

IrssiX::Async - run code in the background to keep irssi responsive

=head1 SYNOPSIS

  use IrssiX::Async qw(fork_off);
  
  fork_off $stdin_data, sub {
    # runs in a background process
    ...
  }, sub {
    # runs when the background process completes
    my ($stdout_data, $stderr_data, $exit_status) = @_;
    ...
  };

=head1 DESCRIPTION

Sometimes you want to do something in an irssi script that may take a long
time, such as downloading a file. While you can just use L<LWP::Simple/get> for
this, irssi will hang until the call completes.

This module provides a simple way to run blocking code in the background,
notifying you when it's done. It exports nothing by default.

=head2 Importable functions

=over

=item fork_off $STDIN, $BODY, $DONE

This function will spawn a new process and run C<< $BODY->() >> in it. The new
process won't be able to call any irssi functions, so don't try. All
communication should go through the C<STDIN>, C<STDOUT>, and C<STDERR> handles.
What you pass as C<$STDIN> will arrive on the new process's C<STDIN>.

When the new process exits (by returning from C<$BODY>),
C<< $DONE->($stdout, $stderr, $status) >> will be called. Here C<$stdout> is
the collected standard output of the process, C<$stderr> is the collected
standard error output, and C<$status> is the exit status (probably in the same
format as L<perlvar/"$?">). If anything goes wrong in the setup/creation of the
child process, C<$DONE> is still called with the error message in C<$stderr>
but C<$status> will be C<undef>.

=back

=head1 CAVEATS

L<fork_off> currently closes all open file descriptors (except for C<STDIN>,
C<STDOUT>, and C<STDERR>) in the child process.

=head1 COPYRIGHT & LICENSE

Copyright 2011 Lukas Mai.

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU Lesser General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version.

=cut
