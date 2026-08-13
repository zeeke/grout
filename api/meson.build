# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2024 Robin Jarry

api_headers += files(
  'gr_api.h',
  'gr_api_client_impl.h',
  'gr_bitops.h',
  'gr_clock.h',
  'gr_errno.h',
  'gr_macro.h',
  'gr_net_compat.h',
  'gr_net_types.h',
)
api_headers += configure_file(
  output: 'gr_version.h',
  configuration: configuration_data({
    'GROUT_VERSION': '"' + meson.project_version() + '"',
  }),
)

grout_header = custom_target(
  'grout.h',
  output: 'grout.h',
  command: files('../devtools/gen_api_header.sh') + api_headers,
  depend_files: api_headers,
  install: true,
  capture: true,
  install_dir: get_option('includedir') / 'grout',
  install_tag: 'man',
)

api_src = files('string.c')
if compiler.has_function('register_printf_specifier', prefix: '#include <printf.h>')
  api_src += files('printf.c')
endif
src += api_src
cli_src += api_src

api_inc += include_directories('.')

if compiler.has_function('register_printf_specifier', prefix: '#include <printf.h>')
  tests += [
    {
      'sources': files('printf_test.c', 'printf.c'),
      'link_args': [],
    },
  ]
endif
tests += [
  {
    'sources': files('string_test.c', 'string.c'),
    'link_args': [],
  },
]
