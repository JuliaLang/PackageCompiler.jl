from setuptools import setup, Extension
import shutil
import os

extension = Extension('hello',
    sources = ['pymodule.c'],
    include_dirs = ['C:\\Users\\sdani\\.julia\\v0.6\\WinRPM\\deps\\usr\\x86_64-w64-mingw32\\sys-root\\mingw\\include'],
    language = 'c'
)

setup(name='hello', version='1.0',  \
    ext_modules=[extension])
