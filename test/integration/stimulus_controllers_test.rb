require "test_helper"

# A data-controller naming a controller that does not exist fails silently in
# the browser: the page just stops being interactive. This catches that without
# a browser.
class StimulusControllersTest < ActionDispatch::IntegrationTest
  teardown { Product.dataset.delete }

  test "the product pages only name controllers that exist" do
    big = build_product(name: "Big Tee", slug: "big-tee", options: { "Colour" => %w[A B C D E F], "Size" => %w[S M L XL 2XL 3XL] })
    sign_in create_account(superuser: true)

    seen = []
    [ "/admin/products/new", "/admin/products/#{big.id}/edit", "/shop/big-tee" ].each do |path|
      get path
      assert_response :success
      seen.concat(css_select("[data-controller]").flat_map { |element| element["data-controller"].split })
    end

    assert_includes seen, "option-editor"
    assert_includes seen, "variant-filter"
    assert_includes seen, "variant-picker"

    seen.uniq.each do |name|
      path = Rails.root.join("app/javascript/controllers/#{name.tr('-', '_')}_controller.js")
      assert File.exist?(path), "#{name} is used on a page but #{path.relative_path_from(Rails.root)} does not exist"
    end
  end
end
