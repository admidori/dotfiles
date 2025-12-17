#!/usr/bin/env perl

$latex = 'platex %O -kanji=utf8 %T';
$bibtex = 'upbibtex';
$biber = 'biber --bblencoding=utf8 -u -U --output_safechars';
$dvipdf = 'dvipdfmx %O %S';

$max_repeat = 5;
$pdf_mode = 3;
