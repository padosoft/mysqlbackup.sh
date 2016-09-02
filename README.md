
# mysqlbackup.sh
Bash script to daily backup all your database in gzip with weekly history. 

[![Software License][ico-license]](LICENSE.md)

Table of Contents
=================

  * [mysqlbackup.sh](#mysqlbackup.sh)
  * [Table of Contents](#table-of-contents)
  * [Prerequisites](#prerequisites)
  * [Install](#install)
  * [Usage](#usage)
  * [Example](#example)
  * [Contributing](#contributing)
  * [Credits](#credits)
  * [About Padosoft](#about-padosoft)
  * [License](#license)

# Prerequisites

bash

# Install

This package can be installed easy.

``` bash
cd /root/myscript
git clone https://github.com/padosoft/mysqlbackup.sh.git
cd mysqlbackup.sh
chmod +x mysqlbackup.sh
```

If you want to run programmatically, add it to cronjobs manually or execute install script:

``` bash
cd /root/myscript/mysqlbackup.sh
chmod +x install.sh
bash install.sh
```


# Usage
``` bash
bash mysqlbackup.sh
```

## Example
``` bash
bash mysqlbackup.sh
```
For help:
``` bash
bash mysqlbackup.sh
```

# Contributing

Please see [CONTRIBUTING](CONTRIBUTING.md) and [CONDUCT](CONDUCT.md) for details.


# Credits

- [Lorenzo Padovani](https://github.com/lopadova)
- [Padosoft](https://github.com/padosoft)
- [Daniele Vona](danielev@seeweb.it)
- [All Contributors](../../contributors)

# About Padosoft
Padosoft is a software house based in Florence, Italy. Specialized in E-commerce and web sites.

# License

The MIT License (MIT). Please see [License File](LICENSE.md) for more information.

[ico-license]: https://img.shields.io/badge/License-GPL%20v3-blue.svg?style=flat-square
