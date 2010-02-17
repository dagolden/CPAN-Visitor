# Copyright (c) 2010 by David Golden. All rights reserved.
# Licensed under Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License.
# A copy of the License was distributed with this file or you may obtain a 
# copy of the License from http://www.apache.org/licenses/LICENSE-2.0

use strict;
use lib 'inc';
eval "require Pod::WikiDoc";
my $class = $@ ? "Module::Build" : "Module::Build::WikiDoc";
eval "require $class";
my $build = $class->new( 
    module_name => 'CPAN::Visitor',
    dist_author => 'David Golden <dagolden@cpan.org>',
    license => 'apache',
    create_readme => 1,
    create_makefile_pl  => 'traditional',
    requires => {
        'perl' => '5.006',
    },
    build_requires => {
        'Test::More' => 0.62,
    },
    meta_add            => { 
        no_index => { 
            directory => [ qw/ examples inc t xt /],
        },
        resources => {
          repository => "http://github.com/dagolden/CPAN-Visitor/", 
          bugtracker => "http://rt.cpan.org/NoAuth/Bugs.html?Dist=CPAN-Visitor",
        },
    },
);
$build->create_build_script;

