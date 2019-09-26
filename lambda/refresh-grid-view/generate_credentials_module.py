#!/usr/bin/env python3

import os, sys
import json


THIS_SCRIPT_DIR = os.path.dirname(__file__)
CREDENTIALS_DIR = os.path.join(THIS_SCRIPT_DIR, "../../../circleci-failure-tracker-credentials")


with open(os.path.join(CREDENTIALS_DIR, "database-credentials-remote-mview-refresher.json")) as json_fh, open("dr_ci_view_refresh/db_config.py", "w") as output_module_fh:
    creds_dict = json.load(json_fh)

    output_module_fh.write('# This file is autogenerated!\n')
    output_module_fh.write('db_hostname = "%s"\n' % creds_dict["db-hostname"])
    output_module_fh.write('db_username = "%s"\n' % creds_dict["db-user"])
    output_module_fh.write('db_password = "%s"\n' % creds_dict["db-password"])
    output_module_fh.write('db_name = "%s"\n' % "loganci")




