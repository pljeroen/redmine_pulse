# frozen_string_literal: true

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# CA-01/02/03 / FC-CA-31: REGISTRATION CORRECTNESS.
# init.rb registers the `pulse` project_module + :view_pulse permission mapped to
# EXACTLY { pulse: [:index,:show,:refresh], pulse_api: [:portfolio,:project] }; a
# project_menu tab gated on module+permission; the settings partial; and
# config/routes.rb declares EXACTLY the 5 named routes and no others.
#
# RED until A9 wires init.rb + config/routes.rb. The permission/menu/route lookups
# resolve against the LIVE registration (not the test-support stub), so these fail
# until the real registration lands.
class RegistrationTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :users, :roles

  # --- CA-01 / FC-CA-31: permission registered with the EXACT action map --------

  def test_view_pulse_permission_is_registered
    perm = Redmine::AccessControl.permission(:view_pulse)
    assert_not_nil perm, ':view_pulse must be a registered permission (init.rb)'
    assert perm.read?, ':view_pulse must be read:true'
  end

  def test_view_pulse_action_map_is_exact_including_refresh
    perm = Redmine::AccessControl.permission(:view_pulse)
    assert_not_nil perm
    # actions is a flat list "controller/action"; assert the exact set incl. refresh.
    expected = %w[pulse/index pulse/show pulse/refresh
                  pulse_api/portfolio pulse_api/project].sort
    assert_equal expected, perm.actions.sort,
                 'BR-01: action map MUST be exactly index/show/refresh + portfolio/project'
  end

  def test_view_pulse_belongs_to_pulse_project_module
    mod = Redmine::AccessControl.permission(:view_pulse).project_module
    assert_equal :pulse, mod, ':view_pulse must live under the :pulse project_module'
  end

  # --- CA-02 / FC-CA-31: project menu tab, module+permission gated --------------

  def test_project_menu_has_pulse_tab_to_pulse_show
    item = Redmine::MenuManager.items(:project_menu).detect { |i| i.name == :pulse }
    assert_not_nil item, 'a :pulse project_menu tab must be registered'
    assert_equal 'pulse', item.url_for_options(nil)[:controller].to_s if item.respond_to?(:url_for_options)
  end

  # --- R-F: top_menu portfolio link, permission-gated --------------------------

  def test_top_menu_has_pulse_portfolio_link
    item = Redmine::MenuManager.items(:top_menu).detect { |i| i.name == :pulse }
    assert_not_nil item, 'a :pulse top_menu item must be registered (init.rb) so /pulse is reachable from global nav'
    assert_equal '/pulse', item.url,
                 "R-F: the :pulse top_menu item must target the portfolio '/pulse' (got #{item.url.inspect})"
  end

  def test_top_menu_pulse_link_is_permission_gated
    item = Redmine::MenuManager.items(:top_menu).detect { |i| i.name == :pulse }
    assert_not_nil item, 'a :pulse top_menu item must be registered (init.rb)'
    assert_not_nil item.condition,
                   'R-F: the :pulse top_menu item MUST carry an :if condition (gated on view_pulse) so it is hidden from users without the permission'

    # RF-02: surface-only existence of the proc is not enough — execute the
    # condition under both a permitted and an unpermitted principal and assert
    # the ACTUAL gating decision. top_menu invokes the proc as condition.call(nil)
    # (no project context), so we exercise the global allowed_to? path that init.rb
    # uses: proc { User.current.allowed_to?(:view_pulse, nil, global: true) }.
    #
    # Falsifiability: the negative case below FAILS if the proc were proc { true }
    # (always visible); the positive case FAILS if it were proc { false } (always
    # hidden). Strong positive = a REAL non-admin member who holds :view_pulse via
    # a role (admins bypass allowed_to? and would be a weak positive).
    PulseAdapterTestSupport.ensure_pulse_permission!
    prior = User.current
    begin
      # Negative: anonymous holds no view_pulse anywhere -> link MUST be hidden.
      User.current = User.anonymous
      refute item.condition.call(nil),
             'R-F: the :pulse top_menu item MUST be HIDDEN for a principal without :view_pulse (anonymous)'

      # Positive: a real non-admin user holding :view_pulse via a role on a
      # module-enabled project -> the global allowed_to? check passes -> link shown.
      role = create_role!(name: 'PulseNavViewer', permissions: %i[view_pulse])
      project = create_project!(name: 'PulseNav', identifier: 'pulse-nav-gate')
      member = create_user!(login: 'pulsenavviewer', admin: false)
      add_member!(project: project, principal: member, role: role)

      User.current = member
      assert item.condition.call(nil),
             'R-F: the :pulse top_menu item MUST be SHOWN for a non-admin user who holds :view_pulse'
    ensure
      # Do not leak the current user into sibling tests.
      User.current = prior || User.anonymous
    end
  end

  # --- CA-03 / FC-CA-31: EXACTLY the 5 routes, resolving to named actions -------

  def test_html_routes_resolve_to_pulse_controller
    assert_routing({ method: :get, path: '/pulse' },
                   { controller: 'pulse', action: 'index' })
    assert_routing({ method: :get, path: '/projects/abc/pulse' },
                   { controller: 'pulse', action: 'show', id: 'abc' })
    assert_routing({ method: :post, path: '/pulse/refresh' },
                   { controller: 'pulse', action: 'refresh' })
  end

  def test_json_routes_resolve_to_pulse_api_controller
    assert_routing({ method: :get, path: '/pulse/portfolio.json' },
                   { controller: 'pulse_api', action: 'portfolio', format: 'json' })
    assert_routing({ method: :get, path: '/pulse/projects/abc.json' },
                   { controller: 'pulse_api', action: 'project', id: 'abc', format: 'json' })
  end

  def test_routes_file_declares_exactly_five_routes
    # Static: the plugin routes file declares exactly 5 route verbs and nothing else
    # (no route to an unimplemented controller/action).
    path = File.expand_path('../../../config/routes.rb', File.expand_path(__FILE__))
    src = File.read(path)
    verbs = src.scan(/^\s*(get|post|put|patch|delete|match)\b/).flatten
    assert_equal 5, verbs.size,
                 "exactly 5 route declarations expected (got #{verbs.size}: #{verbs.inspect})"
  end

  def test_no_stale_deliverables_or_coverage_gap_route
    path = File.expand_path('../../../config/routes.rb', File.expand_path(__FILE__))
    src = File.read(path)
    refute_match(/deliverables|coverage_gap/, src,
                 'no route may reference a deferred/unimplemented feature (DEC-12)')
  end
end
