import { NextRequest, NextResponse } from 'next/server'

export async function POST(req: NextRequest) {
  try {
    const { title, description, amount, recipient, category, transferType, targetParaId } = await req.json()

    if (!process.env.KIMI_API_KEY) {
      return NextResponse.json({ error: 'KIMI_API_KEY not set in .env.local' }, { status: 500 })
    }

    const prompt = `You are an AI analyst for Telos DAO, a decentralized autonomous organization managing a multi-chain treasury on Polkadot Hub.

Analyze this governance proposal and provide a structured assessment:

PROPOSAL DETAILS:
- Title: ${title}
- Description: ${description}
- Amount: ${amount} WND
- Category: ${category}
- Transfer Type: ${transferType === 0 ? 'Local (Polkadot Hub)' : `Cross-Chain XCM to Parachain ${targetParaId}`}
${recipient ? `- Recipient: ${recipient}` : ''}

Provide your analysis in EXACTLY this format:

SUMMARY
[2-3 sentences explaining what this proposal does in plain English]

RISK_LEVEL
[ONE of: LOW | MEDIUM | HIGH]

RISK_FACTORS
[Bullet points of any concerns. If none, write "No significant risk factors identified."]

RECOMMENDATION
[ONE of: APPROVE | REVIEW | REJECT] - [One sentence reason]

Be concise, objective, and focused on protecting treasury funds.`

    const response = await fetch('https://api.moonshot.ai/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${process.env.KIMI_API_KEY}`,
      },
      body: JSON.stringify({
        model: 'moonshot-v1-8k',
        messages: [{ role: 'user', content: prompt }],
        max_tokens: 500,
        temperature: 0.3,
      }),
    })

    const responseText = await response.text()

    if (!response.ok) {
      console.error('Kimi API error:', response.status, responseText)
      return NextResponse.json(
        { error: `Kimi API error ${response.status}: ${responseText}` },
        { status: 500 }
      )
    }

    const data = JSON.parse(responseText)
    const text = data.choices[0].message.content

    // Parse sections
    const summaryMatch = text.match(/SUMMARY\n([\s\S]*?)(?=\nRISK_LEVEL|\n\nRISK_LEVEL)/)
    const riskLevelMatch = text.match(/RISK_LEVEL\n(LOW|MEDIUM|HIGH)/)
    const riskFactorsMatch = text.match(/RISK_FACTORS\n([\s\S]*?)(?=\nRECOMMENDATION|\n\nRECOMMENDATION)/)
    const recommendationMatch = text.match(/RECOMMENDATION\n([\s\S]*)$/)

    const summary = summaryMatch?.[1]?.trim() || text
    const riskLevel = riskLevelMatch?.[1]?.trim() || 'MEDIUM'
    const riskFactors = riskFactorsMatch?.[1]?.trim() || ''
    const recommendation = recommendationMatch?.[1]?.trim() || ''

    const onChainSummary = `[AI Analysis] Risk: ${riskLevel} | ${summary} | ${recommendation}`

    return NextResponse.json({
      summary,
      riskLevel,
      riskFactors,
      recommendation,
      onChainSummary,
      fullText: text,
    })
  } catch (error) {
    console.error('AI summarizer error:', error)
    return NextResponse.json(
      { error: `Failed to generate summary: ${error instanceof Error ? error.message : String(error)}` },
      { status: 500 }
    )
  }
}