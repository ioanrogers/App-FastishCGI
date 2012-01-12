#!env perl

use strict;
use warnings;

use YAML::Any;
use CGI;

my $q = CGI->new;

print $q->header
 . $q->start_html
 . $q->h1('Hello ' . $q->param('fname'))
 . "<hr>"
 . $q->h2('POST Dump');

my $params = $q->Vars;
print "<blockquote>" . Dump($params) . "</blockquote>";


