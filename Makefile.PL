use ExtUtils::MakeMaker;

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME         => 'Apache::Session::Browseable',
    VERSION      => '0.9',
    PREREQ_PM    => { 'Apache::Session' => 0, },
    (
        $] >= 5.005
        ?    ## Add these new keywords supported since 5.005
          (
            ABSTRACT_FROM => 'lib/Apache/Session/Browseable.pod' ,
            AUTHOR => 'Xavier Guimard <x.guimard@free.fr>'
          )
        : ()
    ),
);
