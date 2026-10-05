    move    $v0, $zero
1:  andi    $t0, $a0, 1
    addu    $v0, $v0, $t0
    srl     $a0, $a0, 1
    bnez    $a0, 1b
    nop
    jr      $ra
    nop
