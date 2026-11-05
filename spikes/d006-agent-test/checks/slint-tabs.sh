K=~/agent-test/tools/k.sh
CT() { echo "-P Control_L -P $1 -p $1 -p Control_L"; }
$K t0 -k Down -k Down -k Down
$K t1 $(CT t)
$K t2 -k Down -k Down
$K t3 -P Control_L -P Shift_L -P Tab -p Tab -p Shift_L -p Control_L
$K t4 -P Control_L -P Tab -p Tab -p Control_L
$K t5 -P Control_L -P w -p w -p Control_L
$K t6 -P Control_L -P w -p w -p Control_L
