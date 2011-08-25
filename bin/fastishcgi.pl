#!/usr/bin/env perl

use strict;
use warnings;

use Getopt::Long qw/:config no_ignore_case bundling/;
use App::FastishCGI;
use Pod::Usage;

my $opt = {
    port   => 4001,
    ip     => '127.0.0.1',
    debug  => 0,
    stderr => 0,
};

sub get_options {

    # TODO ipv6
    GetOptions( $opt, 'help|h', 'manual|m', 'ip=s', 'port|p=i', 'socket|s=s', 'debug|D!', 'stderr!', 'daemonise|d!' )
        or pod2usage();

    pod2usage(2) if $opt->{help};
    pod2usage(1) if $opt->{manual};
    
}

get_options();

my $app = App::FastishCGI->new($opt);

$app->start_listening;

__END__

=head1 NAME

fastishcgi.pl

=head1 SYNOPSIS

fastishcgi.pl [options]

Options:
--help            brief help message

=head1 OPTIONS

=over 8

=item B<--help|-h>

Basic help message

=item B<--manual|-m>

Full manual

=item B<--ip> <ip address>

IP to listen on, defaults to 127.0.0.1

=item B<--port|-p> <port>

Port to listen on, defaults to 4001

=item B<--socket|-s> <path>

UNIX socket to listen on. Defaults to INET socket.

=item B<--debug|-D>

Debugging messages will be enabled and outputted on STDERR

=item B<--stderr>

By default, errors are sent to syslog only. This flag also copies errors to stderr,
which usually gets logged by the webserver

=item B<--daemonise|-d>

Backgrounds the process. Not implemented

=back

=cut


