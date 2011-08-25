package App::FastishCGI;

use strict;
use warnings;

# ABSTRACT: provide CGI support to webservers which don't have it

use Net::Async::FastCGI;
use IO::Async::Loop;
use Data::Dumper;
use File::Basename;
use IPC::Open3 qw//;
use IO::Handle;
use Sys::Syslog;
use Carp;

sub daemonise {

    # TODO optionally use an existing CPAN mod to daemonise for
    # systems that don't use systemd or upstart
    log_info('"daemonise" is not available');
    return;
}

sub set_signal_handlers {
    my ($self) = @_;

    $SIG{TERM} = sub { log_info("Received SIGTERM... Shutting down"); exit };
    $SIG{INT} = sub {
        log_info("Received SIGINT... Shutting down");
        $self->{sock}->shutdown(2);
        exit;
    };
}

sub log_error {
    my ( $self, $err_str, $req ) = @_;

    if ( $self->{stderr} && defined $req ) {
        $req->print_stderr($err_str);
    }

    syslog( 'err', $err_str );
    return;
}

sub log_info {
    syslog( 'info', $_[0] );
    return;
}

sub log_die {
    syslog( 'crit', $_[0] );
    croak $_[0];
}

sub log_debug {
    my ( $self, $err_str ) = @_;
    if ( $self->{debug} ) {
        printf STDERR "[%s] %s - %s\n", $$, time, $err_str;
    }
    return;
}

sub html_error {
    my ( $self, $req, $err_str ) = @_;
    $self->log_error( $err_str, $req );

    $req->print_stdout("Content-type: text/html\r\n\r\n");

    my $html =
        "<html>\n"
      . "<body>\n"
      . "<h1>CGI Error</h2>\n"
      . "<h2>Filename: "
      . $req->param('SCRIPT_FILENAME')
      . "</h2>\n"
      . "<blockquote>$err_str</blockquote>" . "<pre>"
      . Dumper( $req->params )
      . "</pre>"
      . "</body>\n"
      . "</html>\n";

    $req->print_stdout($html);
    $req->finish(500);
    return;
}

sub setup_env {
    my ( $self, $req ) = @_;

    $self->log_debug('Setting environment');

    # remove everything we don't need from the environment
    foreach my $key ( keys %ENV ) {
        delete $ENV{$key};
    }

    my $params = $req->params;

    foreach my $key ( keys %{$params} ) {
        $ENV{$key} = $params->{$key};
    }

    return;
}

sub request_loop {
    my ( $self, $fcgi, $req ) = @_;
    
    $req->set_encoding(undef);    # preserve whatever the script sends

    my $script_filename = $req->param('SCRIPT_FILENAME');
    my $script_dir      = dirname $script_filename;

    $self->log_debug("Request for '$script_filename'");
    $self->log_debug( Dumper( $req->params ) );

    chdir $script_dir;            # for scripts that use relative paths

    my $post_data;
    if ( ( $req->param('REQUEST_METHOD') eq 'POST' ) && ( $req->param('CONTENT_LENGTH') + 0 > 0 ) )
    {
        my $req_len = 0 + $req->param('CONTENT_LENGTH');
        $self->log_debug( "Request length " . $req_len );
        $post_data = $req->read_stdin($req_len);
    }

    if (   ( !-x $script_filename )
        && ( !-s $script_filename )
        && ( !-r $script_filename ) )
    {
        $self->html_error( $req,
            "$script_filename: File may not exist or is not executable by this process" );
        return;
    }

    $self->setup_env($req);
    $self->log_debug( "Running " . $script_filename );

    my $wtr = IO::Handle->new;
    my $rdr = IO::Handle->new;
    my $err = IO::Handle->new;

    my $pid = IPC::Open3::open3( $wtr, $rdr, $err, $script_filename );

    if ( !$pid ) {
        $self->html_error( $req, "$script_filename: Failed to open script: $!" );
        return;
    }

    if ( defined $post_data ) {
        $self->log_debug( "post data " . $post_data );
        $wtr->print($post_data);
    }

    # if there isn't a content type header, nginx gives a 502
    # is it worth us checking and inserting one?
    while (1) {
        if ( my $in = $rdr->getline ) {
            $req->print_stdout($in);
        }
        if ( my $in2 = $err->getline ) {
            $self->log_error( $in2, $req );
        }
        if ( $rdr->eof ) {
            last;
        }

    }
    waitpid( $pid, 0 );

    if ( $? != 0 ) {
        my $child_exit_status = $? >> 8;
        $self->log_error(
            "Script $script_filename exited abnormally, with status: $child_exit_status");
    }

    $req->finish(200);

    return;

}

sub new {
    my $this  = shift;
    my $class = ref($this) || $this;
    my %opt   = ( ref $_[0] eq 'HASH' ) ? %{ $_[0] } : @_;
    my $self  = bless \%opt, $class;
    $self->log_debug(Dumper($self)) if $self->{debug};
    $self->_init;
    return $self;
}

sub _init {
    my $self = shift;
    $self->set_signal_handlers;

    openlog( 'fastishcgi', "ndelay,pid", 'user' );

    if ( $self->{daemonise} ) {
        $self->daemonise();
    }

    # TODO IO::Socket::INET6
    if ( defined $self->{socket} ) {
        $self->log_debug( sprintf 'Listening on UNIX socket: %s', $self->{socket} );

# TODO deleting the socket file avoids address in use errors, but how to use systemd's socket stuff?
        unlink $self->{socket} if -e $self->{socket};
        $self->{sock} = IO::Socket::UNIX->new( Local => $self->{socket}, Listen => 1 )
          or die $!;
    } else {
        $self->log_debug( sprintf 'Listening on INET socket: %s:%s', $self->{ip}, $self->{port} );
        $self->{sock} = IO::Socket::INET->new(
            LocalAddr => $self->{ip},
            LocalPort => $self->{port},
            Listen    => 1
        );
    }

}

sub start_listening {

    my $self = shift;

    my $fcgi = Net::Async::FastCGI->new(
        handle     => $self->{sock},
        on_request => sub {
            my ( $fcgi, $req ) = @_;
            $self->request_loop( $fcgi, $req ),;
        },

        #on_listen_error  => sub { $self->log_die("Cannot listen\n"); },
        #on_resolve_error => sub { $self->log_error("Cannot resolve - $_[0]\n"); },
    );

    $self->log_debug('Entering listen loop');
    my $loop = IO::Async::Loop->new();

    $loop->add($fcgi);

    #   $fcgi->listen(%listen_args);
    $loop->loop_forever;

}

1;

__END__

=head1 NAME

App::FastishCGI

=cut
