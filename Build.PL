use Module::Build;
# See perldoc Module::Build for details of how this works

Module::Build->new
    ( module_name     => 'Apache::Session::Browseable',
      license         => 'perl',
      clean => { FILES => 'tmp.db', },
      recommends=> {'DBI'       => 0,'Net::LDAP' => 0.38,},
      test_requires=>{DBI=>0,'DBD::SQLite'=>0,},
      dist_version => '1.0',
    )->create_build_script;
