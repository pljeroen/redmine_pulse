# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).
#
# THIRD-PARTY NOTICE — the `#stub` method body below is vendored, faithfully
# adapted, from minitest's `Object#stub` (lib/minitest/mock.rb):
#
#   minitest is Copyright (c) Ryan Davis, seattle.rb, and is released under the
#   MIT License. Permission is hereby granted, free of charge, to any person
#   obtaining a copy of this software and associated documentation files (the
#   "Software"), to deal in the Software without restriction, including without
#   limitation the rights to use, copy, modify, merge, publish, distribute,
#   sublicense, and/or sell copies of the Software, and to permit persons to whom
#   the Software is furnished to do so, subject to the above copyright notice and
#   this permission notice being included in all copies or substantial portions of
#   the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
#
# MIT is GPL-compatible, so the combined file ships under GPL-2.0-only (above)
# with the MIT-licensed portion attributed here.

# Portable Object#stub — TEST SUPPORT ONLY.
#
# minitest 6.x (bundled by Redmine 7 / Rails 8.1) dropped the `minitest/mock`
# feature that defines `Object#stub`; minitest 5.x (Redmine 6.1 / Rails 7.2) still
# ships it. The plugin's suites use only `#stub` (the `obj.stub(:name, callable) { }`
# form), so this file provides a behaviour-identical implementation, loaded ONLY
# when `require 'minitest/mock'` fails (i.e. `Object#stub` is otherwise undefined).
# On minitest 5.x the native implementation is used and this file is never loaded.
#
# The body is vendored faithfully from minitest's `Object#stub` (MIT-licensed):
# it aliases the original singleton method aside, installs a replacement that calls
# `val_or_callable` when it responds to `:call` (else returns it) for the duration
# of the block, then restores the original in an `ensure`. Ruby 3.2+ kwargs form
# only (the MT_KWARGS_HACK / 2.7 branch is intentionally omitted).
class Object
  unless method_defined?(:stub) || private_method_defined?(:stub)
    def stub(name, val_or_callable, *block_args, **block_kwargs, &block)
      new_name = "__pulse_stub__#{name}"
      metaclass = class << self; self; end

      if respond_to?(name) && !methods.map(&:to_s).include?(name.to_s)
        metaclass.send :define_method, name do |*args, **kwargs|
          super(*args, **kwargs)
        end
      end

      metaclass.send :alias_method, new_name, name

      metaclass.send :define_method, name do |*args, **kwargs, &blk|
        if val_or_callable.respond_to? :call
          if kwargs.empty?
            val_or_callable.call(*args, &blk)
          else
            val_or_callable.call(*args, **kwargs, &blk)
          end
        else
          if blk
            if block_kwargs.empty?
              blk.call(*block_args)
            else
              blk.call(*block_args, **block_kwargs)
            end
          end
          val_or_callable
        end
      end

      block[self]
    ensure
      metaclass.send :undef_method, name
      metaclass.send :alias_method, name, new_name
      metaclass.send :undef_method, new_name
    end
  end
end
