# .vagrantcfg.rb

A .vagrantcfg.rb file can be placed along side each Vagrantfile ( either the raw file or a symlink )
This file is expected to define the class ExtendedVagrantConfig that on initialize performs any additional actions
the author wants to happen for his project directory.

Example:

```ruby
class ExtendedVagrantConfig
    def initialize(config)
        config.vm.synced_folder ".", "/home/vagrant/hostcwd"
    end
end
```

