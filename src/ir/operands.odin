package ir

// operands lets opt list and rewrite the uses of a value through one switch. The fields come in a
// fixed order, so an index into `found` names the same field again after the variant moved.
operands :: proc(variant: ^Variant, found: ^[dynamic]^Value_ID) {
	clear(found)
	switch &v in variant {
	case Unreachable, Param, Const_Number, Const_Bool, Const_Undefined, Const_Null, Const_String:
	case Env, Func_Ref, Global_Load, Jump, Fail, Alloc:
	case Binary:
		add_operands(found, &v.left, &v.right)
	case Unary:
		add_operands(found, &v.operand)
	case Compare:
		add_operands(found, &v.left, &v.right)
	case Phi:
		for &edge in v.incoming {
			add_operands(found, &edge.value)
		}
	case Convert:
		add_operands(found, &v.value)
	case New_Array:
		add_operands(found, &v.length)
	case Field_Load:
		add_operands(found, &v.cell)
	case Field_Store:
		add_operands(found, &v.cell, &v.value)
	case Field_Store_Ref:
		add_operands(found, &v.cell, &v.value)
	case Length:
		add_operands(found, &v.value)
	case Reserve:
		add_operands(found, &v.array)
	case Set_Length:
		add_operands(found, &v.array, &v.length)
	case Bounds_Check:
		add_operands(found, &v.array, &v.index)
	case Element_Load:
		add_operands(found, &v.array, &v.index)
	case Element_Store:
		add_operands(found, &v.array, &v.index, &v.value)
	case Element_Store_Ref:
		add_operands(found, &v.array, &v.index, &v.value)
	case Unit_Load:
		add_operands(found, &v.text, &v.index)
	case Ascii_Cell:
		add_operands(found, &v.unit)
	case Layout_Test:
		add_operands(found, &v.cell)
	case Null_Test:
		add_operands(found, &v.value)
	case Non_Null:
		add_operands(found, &v.value)
	case Same_Cell:
		add_operands(found, &v.a, &v.b)
	case Tag_Test:
		add_operands(found, &v.value)
	case Box:
		add_operands(found, &v.value)
	case Unbox:
		add_operands(found, &v.value)
	case Global_Store:
		add_operands(found, &v.value)
	case Make_Closure:
		add_operands(found, &v.env)
	case Call:
		for &arg in v.args {
			add_operands(found, &arg)
		}
	case Call_Closure:
		add_operands(found, &v.callee)
		for &arg in v.args {
			add_operands(found, &arg)
		}
	case Call_Runtime:
		for &arg in v.args {
			add_operands(found, &arg)
		}
	case Intrinsic:
		for &arg in v.args {
			add_operands(found, &arg)
		}
	case Branch:
		add_operands(found, &v.condition)
	case Return:
		add_operands(found, &v.value)
	}
}

@(private = "file")
add_operands :: proc(found: ^[dynamic]^Value_ID, fields: ..^Value_ID) {
	for field in fields {
		if field^ != NO_VALUE {
			append(found, field)
		}
	}
}
