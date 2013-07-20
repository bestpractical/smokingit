use inc::Module::Install;

name        'Smokingit';
version     '0.01';
requires    'Jifty' => '1.01209';
requires    'Git::PurePerl';
requires    'Plack::Middleware::CrossOrigin';
requires    'IM::Engine';
requires    'String::IRC';

# requires Web::Hippie from git://github.com/alexmv/Web-Hippie.git

WriteAll;
