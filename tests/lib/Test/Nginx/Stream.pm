package Test::Nginx::Stream;

# (C) Andrey Zelenkov
# (C) Nginx, Inc.
# (C) 2024 Web Server LLC

# Module for nginx stream tests.

###############################################################################

use warnings;
use strict;

use base qw/ Exporter /;
our @EXPORT_OK = qw/ stream dgram /;

use Test::More qw//;
use IO::Select;
use IO::Socket;

use Test::Nginx;

sub stream {
	return Test::Nginx::Stream->new(@_);
}

sub dgram {
	unshift(@_, "PeerAddr") if @_ == 1;

	return Test::Nginx::Stream->new(
		Proto => "udp",
		@_
	);
}

sub new {
	my $self = {};
	bless $self, shift @_;

	unshift(@_, "PeerAddr") if @_ == 1;

	eval {
		local $SIG{ALRM} = sub { die "timeout\n" };
		local $SIG{PIPE} = sub { die "sigpipe\n" };
		alarm(8);

		$self->{_socket} = IO::Socket::INET->new(
			Proto => "tcp",
			PeerAddr => '127.0.0.1',
			@_
		)
			or die "Can't connect to nginx: $!\n";

		if ({@_}->{'SSL'}) {
			require IO::Socket::SSL;
			IO::Socket::SSL->start_SSL(
				$self->{_socket},
				SSL_version => 'SSLv23',
				SSL_verify_mode =>
					IO::Socket::SSL::SSL_VERIFY_NONE(),
				@_
			)
				or die $IO::Socket::SSL::SSL_ERROR . "\n";

			my $s = $self->{_socket};
			log_in("ssl cipher: " . $s->get_cipher());
			log_in("ssl cert: " . $s->peer_certificate('subject'));
		}

		alarm(0);
	};
	alarm(0);
	if ($@) {
		log_in("died: $@");
	}

	$self->{_socket}->autoflush(1);

	return $self;
}

sub DESTROY {
	my $self = shift;
	$self->{_socket}->close();
}

sub write {
	my ($self, $message, %extra) = @_;
	my $s = $self->{_socket};

	local $SIG{PIPE} = 'IGNORE';

	$s->blocking(0);
	while (IO::Select->new($s)->can_write($extra{write_timeout} || 1.5)) {
		my $bytes_written = $s->syswrite($message);

		unless (defined $bytes_written) {
			Test::More::note("write(): error while writing to socket: $!");
			last;
		}

		last if $bytes_written == 0;

		log_out(substr($message, 0, $bytes_written));

		$message = substr($message, $bytes_written);
		last unless length $message;
	}

	if (length $message) {
		$s->close();
	}
}

sub read {
	my ($self, %extra) = @_;
	my ($s, $buf);

	$s = $self->{_socket};

	$s->blocking(0);
	while (IO::Select->new($s)->can_read($extra{read_timeout} || 8)) {
		my $bytes_read = $s->sysread($buf, 1024);

		Test::More::note("$0: read(): error while reading from socket: $!")
			if !defined $bytes_read;

		next if !defined $bytes_read && $!{EWOULDBLOCK};

		last;
	}

	log_in($buf);
	return $buf;
}

sub io {
	my $self = shift;

	my ($data, %extra) = @_;
	my $length = $extra{length};
	my $read = $extra{read};

	$read = 1 if !defined $read
		&& $self->{_socket}->socktype() == &SOCK_DGRAM;

	$self->write($data, %extra);

	$data = '';
	while (1) {
		last if defined $read && --$read < 0;

		my $buf = $self->read(%extra);
		last unless defined $buf and length($buf);

		$data .= $buf;
		last if defined $length && length($data) >= $length;
	}

	return $data;
}

sub sockaddr {
	my $self = shift;
	return $self->{_socket}->sockaddr();
}

sub sockhost {
	my $self = shift;
	return $self->{_socket}->sockhost();
}

sub sockport {
	my $self = shift;
	return $self->{_socket}->sockport();
}

sub socket {
	my ($self) = @_;
	$self->{_socket};
}

###############################################################################

1;

###############################################################################
