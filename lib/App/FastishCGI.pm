package App::FastishCGI;

use strict;
use warnings;

# ABSTRACT: provide CGI support to webservers which don't have it

use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::FCGI;

use Data::Dumper;
use File::Basename;
use IPC::Open3 qw//;
use IO::Handle;
use Sys::Syslog;
use Carp;

# TODO optionally use an existing CPAN mod to daemonise for
# systems that don't use systemd or upstart

sub shutdown_signal {
    my ( $self, $SIG ) = @_;
    $self->log_info( sprintf 'Received SIG%s. Shutting down after handling %d requests',
        $SIG, $self->{requests_total} );
    exit;
}

sub set_signal_handlers {
    my ($self) = @_;

    $self->{sigint} =
      AnyEvent->signal( signal => "INT", cb => sub { $self->shutdown_signal('INT') } );
    $self->{sigterm} =
      AnyEvent->signal( signal => "TERM", cb => sub { $self->shutdown_signal('TERM') } );
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
    syslog( 'info', $_[1] );
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

    my $html_str = <<HTML;
<html>
<head>
<title>CGI Error:: %s</title>
%s
<head>
<body>
<h1>CGI Error</h2>
<h2>Filename: %s</h2>
<blockquote class="err_msg">%s</blockquote>
<pre class="err_dump">
%s
</pre>
</body>
</html>

HTML

    my $html = sprintf $html_str, $req->param('SCRIPT_FILENAME'), $self->{css},
      $req->param('SCRIPT_FILENAME'),
      $err_str, Dumper( $req->params );

    $req->respond(
        $html,
        'Content-Type' => 'text/html',
        'Status'       => 500
    );
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

sub show_active_requests {
    my ($self) = @_;

    my $reqs = 'Active requests [' . $self->{requests_total} .']';
    foreach my $key ( keys %{ $self->{requests} } ) {
        $reqs .= " $key,";
    }
    $self->log_debug($reqs);

}

sub clear_request {
    my ( $self, $rid ) = @_;

    delete $self->{requests}->{$rid};
    $self->log_debug("Removed request $rid");

}

sub request_loop {
    my ( $self, $req ) = @_;

    $self->{requests_total}++;
    my $rid = $self->{requests_total};
    $self->{requests}->{$rid}->{buffer} = '';

    my $script_filename = $req->param('SCRIPT_FILENAME');
    my $script_dir      = dirname $script_filename;

    if ( $self->{debug} ) {
        $self->log_debug( sprintf '[%d] New request for "%s"', $rid, $script_filename );
        $self->log_debug( "[$rid] Request Object:\n" . Dumper( $req->params ) );
        $self->log_debug("[$rid] Setting environment");
    }
    $self->setup_env($req);

    chdir $script_dir;    # for scripts that use relative paths
    if (   ( !-x $script_filename )
        && ( !-s $script_filename )
        && ( !-r $script_filename ) )
    {
        $self->html_error( $req,
            "$script_filename: File may not exist or is not executable by this process" );
        return;
    }

    $self->log_debug( "Running " . $script_filename );

    my ( $wtr, $rdr, $err );

    my $pid = IPC::Open3::open3( $wtr, $rdr, $err, $script_filename );

    if ( !$pid ) {
        $self->html_error( $req, "$script_filename: Failed to open script: $!" );
        return;
    }

    if ( ( $req->param('REQUEST_METHOD') eq 'POST' ) && ( $req->param('CONTENT_LENGTH') + 0 > 0 ) )
    {
        my $req_len = 0 + $req->param('CONTENT_LENGTH');
        $self->log_debug("[$rid] Request length $req_len");
        my $post_data = $req->read_stdin($req_len);
        $self->log_debug("[$rid] POST data $post_data");
        $wtr->print($post_data);
    }

    $self->{requests}->{$rid}->{handle} = AnyEvent::Handle->new(
        fh      => $rdr,
        on_read => sub {
            $self->{requests}->{$rid}->{buffer} .= $_[0]->rbuf;
            $_[0]->rbuf = '';
        },
        on_eof => sub {
            undef $self->{requests}->{$rid}->{handle};
        },
    );

    $self->{requests}->{$rid}->{child} = AnyEvent->child(
        pid => $pid,
        cb  => sub {
            my ( $pid, $return_val ) = @_;
            my $status = $return_val >> 8;

            # XXX the cgi spec, as far as I have found, is like shell scripting in
            # that scripts should return 0 on success. However some of the scripts I
            # need to use return 1 instead.
            if ( $status != 0 && $status != 1 ) {
                $self->html_error( $req,
                    "Script $script_filename exited abnormally, with status: $status" );
            } else {
                $self->log_debug("[$rid] Script $script_filename completed");
                $req->print_stdout( $self->{requests}->{$rid}->{buffer} );
                $req->finish;
            }
            $self->clear_request($rid);
        },
    );

    $self->{requests}->{$rid}->{timer} = AnyEvent->timer(
        after => $self->{timeout},
        cb    => sub {
            $self->html_error($req, "Script '$script_filename' exceeded timeout value");
            $self->clear_request($rid);
        }
    );

    $self->log_debug("[$rid] setup");
    $self->show_active_requests if $self->{debug};

    return;

}

sub new {
    my $this  = shift;
    my $class = ref($this) || $this;
    my %opt   = ( ref $_[0] eq 'HASH' ) ? %{ $_[0] } : @_;
    my $self  = bless \%opt, $class;
    $self->log_debug( Dumper($self) ) if $self->{debug};
    $self->_init;

    return $self;
}

sub _init {
    my $self = shift;
    $self->set_signal_handlers;

    openlog( 'fastishcgi', "ndelay,pid", 'user' );

    # stylesheet is a url or path for web server. If none is supplied add default
    if ( $self->{css} ) {
        $self->{css} = sprintf '<link href="%s" rel="stylesheet" type="text/css">', $self->{css};
    } else {
        $self->{css} = <<CSS;
<style type="text/css">
pre { padding: 1em; border: 2px solid white }
body {color: red; background-color: black; }
</style>
CSS

    }

    $self->{requests_total} = 0;
    $self->{requests}       = {};

}

sub main_loop {

    my $self = shift;
    my $fcgi;

    # TODO IO::Socket::INET6
    if ( defined $self->{socket} ) {
        $self->log_debug( sprintf 'Listening on UNIX socket: %s', $self->{socket} );
        $fcgi = new AnyEvent::FCGI(
            socket     => $self->{socket},
            on_request => sub { $self->request_loop(@_); }
        );

    } else {
        $self->log_debug( sprintf 'Listening on INET socket: %s:%s', $self->{ip}, $self->{port} );
        $fcgi = new AnyEvent::FCGI(
            port       => $self->{port},
            host       => $self->{ip},
            on_request => sub { $self->request_loop(@_) }
        );
    }

    $self->log_debug( 'Entering main listen loop using ' . $AnyEvent::MODEL );
    AnyEvent::CondVar->recv;

}

1;

