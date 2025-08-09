{ pkgs ? import <nixpkgs> { } }:
pkgs.mkShell {
  VULKAN_INCLUDE_PATH = "${pkgs.lib.makeIncludePath [pkgs.vulkan-headers]}";
  VULKAN_SDK = "${pkgs.vulkan-headers}";
  VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
  LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath [pkgs.vulkan-loader]}";

  buildInputs = with pkgs; [
    vulkan-tools
    vulkan-loader
    vulkan-headers
    vulkan-validation-layers
  ];
}
