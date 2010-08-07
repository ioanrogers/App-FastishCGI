#!/usr/bin/env perl

use strict;
use warnings;

use Getopt::Long;
use App::FastishCGI;
use Pod::Usage;

my $opt = {
    port   => 4001,
    debug  => 0,
    stderr => 0,
};

sub get_options {

    GetOptions( $opt, 'help|?', 'ip=s', 'port|p=i', 'debug|d!', 'stderr!', 'foreground|f!' )
      or pod2usage(2);

    pod2usage(1) if $opt->{help};

}

get_options();

my $app = App::FastishCGI->new($opt);

$app->start_listening;

__END__

=head1 NAME

fastishcgi.pl

=head1 SYNOPSIS

fastishcgi.pl [options] [file ...]

Options:
--help            brief help message

=head1 OPTIONS

=over 8

=item B<--help|-h>

This help message

=item B<--ip>

IP to listen on, defaults to 127.0.0.1

=item B<--port|-p>

Port to listen on, defaults to 4001

=item B<--debug|-d>

Prints a lot of stuff to the syslog

=item B<--stderr>

By default, errors are sent to syslog only. This flag also copies errors to stderr,
which usually gets logged by the webserver

=back

=cut


