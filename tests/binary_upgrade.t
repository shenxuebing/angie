#!/usr/bin/perl

# (C) 2024 Web Server LLC
# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Tests for binary upgrade - upgrading an executable file on the fly.

###############################################################################

use warnings;
use strict;
use feature 'state';

use Test::Most;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http unix/)->plan(2)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       unix:%%TESTDIR%%/unix.sock;
        server_name  localhost;
    }
}

EOF

my $d = $t->testdir();

$t->run();

###############################################################################

subtest 'upgrade followed by termination of the old master process' => sub {
	my $pid = $t->read_file('nginx.pid');
	chomp($pid);

	# upgrade the executable on the fly
	my $new_pid = upgrade($t, $pid)
		or return;

	# terminate old master process
	terminate_pid($t, $pid, 'QUIT');

	is($t->read_file('nginx.pid'), "$new_pid\n", 'master pid changed');

	is_deeply(get_master_processes_pids(), [$new_pid],
		'only new master process is running');

	ok(-e "$d/unix.sock", 'unix socket exists on old master shutdown');
};

my $is_previous_subtest_failed = !(Test::More->builder->summary)[-1];
subtest 'upgrade followed by termination of the new master process' => sub {

	# it may be dangerous to continue if previous subtest failed
	return
		if $is_previous_subtest_failed;

	my $pid = $t->read_file('nginx.pid');
	chomp($pid);

	# upgrade the executable on the fly
	my $new_pid = upgrade($t, $pid)
		or return;

	# terminate new master process
	terminate_pid($t, $new_pid, 'TERM');

	is($t->read_file('nginx.pid'), "$pid\n", 'master pid not changed');

	is_deeply(get_master_processes_pids(), [$pid],
		'only old master process is running');

	ok(-e "$d/unix.sock", 'unix socket exists on new master termination');
};

###############################################################################

sub upgrade {
	my ($t, $pid) = @_;

	ok($pid, 'old master pid file is not empty')
		or return;

	is_deeply(get_master_processes_pids(), [$pid],
		'only old master process is running') or return;

	# upgrade the executable on the fly
	kill 'USR2', $pid;

	my $errors;
	my $found = 0;

	for (1 .. 150) {
		$errors = read_error_log($t);
		$found = grep { $_ =~ /, changing binary/ } @{ $errors };
		last if $found;
		select undef, undef, undef, 0.02;
	}

	ok($found, 'the first USR2 signal was received')
		or return;

	# second USR2 signal before handling the first one shouldn't cause issues
	kill 'USR2', $pid;

	$found = 0;
	for (1 .. 150) {
		$found = grep { $_ =~ /: changing binary/ } @{ $errors };
		last if $found;
		select undef, undef, undef, 0.02;
		$errors = read_error_log($t);
	}

	ok($found, 'the first USR2 signal was handled')
		or return;

	# another USR2 signal during binary upgrade must be ignored
	kill 'USR2', $pid;

	my $expected_error = "$pid#\\d+: the changing binary signal is ignored: "
		. "you should shutdown or terminate before either old or new "
		. "binary's process";

	$t->skip_errors_check('crit', $expected_error);

	# waiting for the error to appear in the log
	$found = 0;
	for (1 .. 150) {
		my $errors = read_error_log($t);
		$found = grep { $_ =~ /$expected_error/ } @{ $errors };
		last if $found;

		select undef, undef, undef, 0.02;
	}

	ok($found, 'the second USR2 signal was ignored');

	# check old and new master processes' pids
	for (1 .. 150) {
		last if -e "$d/nginx.pid" && -e "$d/nginx.pid.oldbin";
		select undef, undef, undef, 0.2;
	}

	ok(-e "$d/nginx.pid.oldbin", 'old master pid file exists')
		or return;

	ok(-e "$d/nginx.pid", 'new master pid file exists')
		or return;

	my $new_pid = $t->read_file('nginx.pid');
	chomp($new_pid);

	isnt($new_pid, $pid, 'master pid changed')
		or return;

	is_deeply(get_master_processes_pids(), [$pid, $new_pid],
		'an old and a new master processes are running')
		or return;

	return $new_pid;
}

sub terminate_pid {
	my ($t, $pid, $signal) = @_;

	kill $signal, $pid;

	for (1 .. 150) {
		last if ! -e "$d/nginx.pid.oldbin";
		select undef, undef, undef, 0.2;
	}

	ok(!-e "$d/nginx.pid.oldbin", 'old master pid deleted');
	ok(-e "$d/nginx.pid", 'new pid exists');
}

# reads only new lines from error.log file
sub read_error_log {
	my $t = shift;

	state $error_log_fh;

	my $test_dir = $t->testdir();

	unless (defined $error_log_fh) {
		open($error_log_fh, '<', $test_dir . '/error.log')
			or die "Can't open $test_dir/error.log: $!";
	}

	seek($error_log_fh, 0, 1);

	my @error_log;
	for my $line (<$error_log_fh>) {
		chomp $line;
		next if $line =~ /\[debug\]/;
		note($line);
		push @error_log, $line;
	}

	return \@error_log;
}

sub get_master_processes_pids {
	my @master_processes = split(/\n/,
		`ps ax | grep '$Test::Nginx::NGINX -p $d' \\
		| grep -v grep | awk '{print \$1}'`);

	return \@master_processes;
}

1;
