use inc::Module::Install;

name        'Smokingit';
version     '0.01';
requires    'Jifty' => '1.01209';
requires    'Git::PurePerl';
requires    'IM::Engine';
requires    'String::IRC';

# requires IM::Engine from git://github.com/sartak/IM-Engine.git
# requires Web::Hippie from git://github.com/alexmv/Web-Hippie.git

WriteAll;
